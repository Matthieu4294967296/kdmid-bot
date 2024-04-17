require 'dotenv/load'
require 'rubygems'
require 'bundler/setup'
Bundler.require(:default)
require 'telegram/bot'
require 'selenium-webdriver'
require 'base64'
require 'securerandom'

class Bot
  attr_reader :link, :client, :current_time
  PASS_CAPTCHA_ATTEMPTS_LIMIT = 5

  def initialize
    @link = "http://#{ENV.fetch('KDMID_SUBDOMAIN')}.kdmid.ru/queue/OrderInfo.aspx?id=#{ENV.fetch('ORDER_ID')}&cd=#{ENV.fetch('CODE')}"
    @client = TwoCaptcha.new(ENV.fetch('TWO_CAPTCHA_KEY'))
    @current_time = Time.now.utc.to_s
    puts 'Init...'
  end

  def notify_user(message)
    puts message
    # `say "#{message}"`
    return unless ENV['TELEGRAM_TOKEN']

    Telegram::Bot::Client.run(ENV['TELEGRAM_TOKEN']) do |bot|
      bot.api.send_message(chat_id: ENV['TELEGRAM_CHAT_ID'], text: message)
    end
  end

  def pass_hcaptcha(driver)
    sleep 5

    wait = Selenium::WebDriver::Wait.new(timeout: 30000)
    element = wait.until { driver.find_element(id: 'ImgCnt') } #class: 'inp') } #class: 'h-captcha') }

    # Find the child <img> element within the parent element
    #tmp_element = element.find_element(id: 'ImgCnt')
    img_element = element.find_element(id: 'ctl00_MainContent_imgSecNum')

    # Extract the 'src' attribute value from the <img> element
    image_url = img_element.attribute('src')
    #return unless element.displayed?

    #sitekey = element.attribute('data-sitekey')
    #puts "sitekey: #{sitekey} url: #{link}"

    #captcha = client.decode_hcaptcha!(sitekey: sitekey, pageurl: link)
    captcha = client.decode_image!(url: image_url)
    captcha_response = captcha.text
    puts "captcha_response: #{captcha_response}"

    3.times do |i|
      puts "attempt: #{i}"
      sleep 2
      ['h-captcha-response', 'g-recaptcha-response'].each do |el_name|
        driver.execute_script(
          "document.getElementsByName('#{el_name}')[0].style = '';
          document.getElementsByName('#{el_name}')[0].innerHTML = '#{captcha_response.strip}';
          document.querySelector('iframe').setAttribute('data-hcaptcha-response', '#{captcha_response.strip}');"
        )
      end
      sleep 3
      driver.execute_script("cb();")
      sleep 3
      break unless element.displayed?
    end
  end


  def pass_ddgcaptcha(driver)
    attempt = 1
    sleep 5

    while driver.find_element(class: 'ddg-captcha').displayed? && attempt <= PASS_CAPTCHA_ATTEMPTS_LIMIT
      puts "attempt: [#{attempt}] let's find the ddg captcha image..."

      checkbox = driver.find_element(class: 'ddg-captcha')
      checkbox.click

      captcha_image = driver.find_element(tag_name: 'iframe').find_element(class: 'ddg-modal__captcha-image')
      driver.execute_script("arguments[0].scrollIntoView(true);", captcha_image)
      captcha_image.screenshot("./captches/#{current_time}.png")

      puts 'save captcha image to file...'
      image_filepath = "./captches/#{current_time}.png"

      puts 'decode captcha...'
      captcha = client.decode!(path: image_filepath)
      captcha_code = captcha.text
      puts "captcha_code: #{captcha_code}"

      text_field = driver.find_element(class: 'ddg-modal__input')
      text_field.send_keys(captcha_code)

      driver.find_element(class: 'ddg-modal__submit').click

      attempt += 1
      sleep 15
    end
  end

  def pass_captcha_on_form(driver)
    puts "let's find the captcha image..."
    captcha_image = driver.find_element(id: 'ctl00_MainContent_imgSecNum')

    puts 'save captcha image to file...'
    image_filepath = "./captches/#{current_time}.png"
    captcha_image.save_screenshot(image_filepath)

    puts 'decode captcha...'
    captcha = client.decode!(path: image_filepath)
    captcha_code = captcha.text
    puts "captcha_code: #{captcha_code}"

    text_field = driver.find_element(id: 'ctl00_MainContent_txtCode')
    text_field.clear
    text_field.send_keys(captcha_code)
    validate_btn = driver.find_element(id: 'ctl00_MainContent_ButtonA')
    validate_btn.click
    
    # Check if the captcha element is still present on the page
    if driver.find_elements(id: 'ctl00_MainContent_imgSecNum').any?
      puts "Captcha element still present, retry solving a new captcha..."
      pass_captcha_on_form(driver) # Retry solving a new captcha
    else
      puts "Captcha element not found, continuing with the normal flow..."
      # Continue with the normal flow of the code
  end
  end

  def click_make_appointment_button(driver)
    wait = Selenium::WebDriver::Wait.new(timeout: 300)
    make_appointment_btn = wait.until { driver.find_element(id: 'ctl00_MainContent_ButtonB') }
    make_appointment_btn.click
  end

  def save_page(driver)
    driver.save_screenshot("./screenshots/#{current_time}.png")
    File.write("./pages/#{current_time}.html", driver.page_source)
  end

  def check_queue
    puts "===== Current time: #{current_time} ====="

    driver = Selenium::WebDriver.for :chrome

    begin
      driver.get link

      sleep 3
      pass_captcha_on_form(driver)

      click_make_appointment_button(driver)

      #save_page(driver)
    
      loop do
        izvini_text_present = driver.find_elements(xpath: "//p[contains(text(), 'Извините, но в настоящий момент')]").any?
        notify_user('New time for an appointment found!') unless izvini_text_present

        puts '=' * 50

        sleep 10 # Wait for 10 seconds before searching again
        driver.navigate.refresh
      end
    ensure
      driver.quit
    end
  rescue Exception => e
    notify_user('exception!')
    raise e
  end
end

Bot.new.check_queue

