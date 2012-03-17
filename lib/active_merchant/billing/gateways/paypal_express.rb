require File.dirname(__FILE__) + '/paypal/paypal_common_api'
require File.dirname(__FILE__) + '/paypal/paypal_express_response'
require File.dirname(__FILE__) + '/paypal_express_common'

module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class PaypalExpressGateway < Gateway
      include PaypalCommonAPI
      include PaypalExpressCommon
      
      self.test_redirect_url = 'https://www.sandbox.paypal.com/cgi-bin/webscr?cmd=_express-checkout&token='
      self.supported_countries = ['US']
      self.homepage_url = 'https://www.paypal.com/cgi-bin/webscr?cmd=xpt/merchant/ExpressCheckoutIntro-outside'
      self.display_name = 'PayPal Express Checkout'
      
      def setup_authorization(money, options = {})
        requires!(options, :return_url, :cancel_return_url)
        
        commit 'SetExpressCheckout', build_setup_request('Authorization', money, options)
      end
      
      def setup_purchase(money, options = {})
        requires!(options, :return_url, :cancel_return_url)
        
        if options[:mobile] == true
          commit 'SetMobileCheckout', build_setup_request('Sale', money, options)
        else
          commit 'SetExpressCheckout', build_setup_request('Sale', money, options)
        end
      end

      def details_for(token, in_mobile_view = nil)
        if in_mobile_view
          commit 'GetMobileCheckoutDetails', build_get_details_request(token, in_mobile_view)
        else
          commit 'GetExpressCheckoutDetails', build_get_details_request(token, in_mobile_view)
        end
      end

      def authorize(money, options = {})
        requires!(options, :token, :payer_id)
        if options[:mobile] == true
          commit 'DoMobileCheckoutPayment', build_sale_or_authorization_request('Authorization', money, options)
        else
          commit 'DoExpressCheckoutPayment', build_sale_or_authorization_request('Authorization', money, options)
        end
      end

      def purchase(money, options = {})
        requires!(options, :token, :payer_id)
        if options[:mobile] == true
          commit 'DoMobileCheckoutPayment', build_sale_or_authorization_request('Sale', money, options)
        else
          commit 'DoExpressCheckoutPayment', build_sale_or_authorization_request('Sale', money, options)
        end
      end

      private
      def build_get_details_request(token, in_mobile_view)
        xml = Builder::XmlMarkup.new :indent => 2
        # this API is not support for mobile
        unless in_mobile_view
          xml.tag! 'GetExpressCheckoutDetailsReq', 'xmlns' => PAYPAL_NAMESPACE do
            xml.tag! 'GetExpressCheckoutDetailsRequest', 'xmlns:n2' => EBAY_NAMESPACE do
              xml.tag! 'n2:Version', API_VERSION
              xml.tag! 'Token', token
            end
          end
        end


        xml.target!
      end

      def build_sale_or_authorization_request(action, money, options)
        currency_code = options[:currency] || currency(money)

        xml = Builder::XmlMarkup.new :indent => 2
        
        if options[:mobile] == true
          xml.tag! 'DoMobileCheckoutPaymentReq', 'xmlns' => PAYPAL_NAMESPACE do
            xml.tag! 'DoMobileCheckoutPaymentRequest' do
              xml.tag! 'Version', MOBILE_API_VERSION, 'xmlns' => 'urn:ebay:apis:eBLBaseComponents'
              xml.tag! 'PaymentAction', action
              xml.tag! 'Token', options[:token]
            end
          end
        else  # else not mobile 
          xml.tag! 'DoExpressCheckoutPaymentReq', 'xmlns' => PAYPAL_NAMESPACE do
            xml.tag! 'DoExpressCheckoutPaymentRequest', 'xmlns:n2' => EBAY_NAMESPACE do
              xml.tag! 'n2:Version', API_VERSION
              xml.tag! 'n2:DoExpressCheckoutPaymentRequestDetails' do
                xml.tag! 'n2:PaymentAction', action
                xml.tag! 'n2:Token', options[:token]
                xml.tag! 'n2:PayerID', options[:payer_id]
                xml.tag! 'n2:PaymentDetails' do
                  xml.tag! 'n2:OrderTotal', amount(money), 'currencyID' => currency_code

                  # All of the values must be included together and add up to the order total
                  if [:subtotal, :shipping, :handling, :tax].all?{ |o| options.has_key?(o) }
                    xml.tag! 'n2:ItemTotal', amount(options[:subtotal]), 'currencyID' => currency_code
                    xml.tag! 'n2:ShippingTotal', amount(options[:shipping]),'currencyID' => currency_code
                    xml.tag! 'n2:HandlingTotal', amount(options[:handling]),'currencyID' => currency_code
                    xml.tag! 'n2:TaxTotal', amount(options[:tax]), 'currencyID' => currency_code
                  end

                  if options[:paymentDetailsItems]
                    options[:paymentDetailsItems].each do |paymentDetailItem|
                      xml.tag! 'n2:PaymentDetailsItem' do
                        xml.tag! 'n2:Name', paymentDetailItem[:name] if paymentDetailItem[:name]
                        xml.tag! 'n2:Number', paymentDetailItem[:number] if paymentDetailItem[:number]
                        xml.tag! 'n2:Quantity', paymentDetailItem[:quantity] if paymentDetailItem[:quantity]
                        xml.tag! 'n2:Amount', amount(paymentDetailItem[:amount]), 'currencyID' => currency_code if paymentDetailItem[:amount]
                        xml.tag! 'n2:Tax', amount(paymentDetailItem[:tax]), 'currencyID' => currency_code if paymentDetailItem[:tax]
                        xml.tag! 'n2:Description', paymentDetailItem[:description]
                      end
                    end
                  end
                  xml.tag! 'n2:NotifyURL', options[:notify_url]
                  xml.tag! 'n2:ButtonSource', application_id.to_s.slice(0,32) unless application_id.blank?
                end
              end
            end
          end
        end

        xml.target!
      end

      def build_setup_request(action, money, options)
        xml = Builder::XmlMarkup.new :indent => 2
        if options[:mobile]
          currency_code = options[:currency] || currency(money)

          xml.tag! 'SetMobileCheckoutReq', 'xmlns' => PAYPAL_NAMESPACE do
            xml.tag! 'SetMobileCheckoutRequest' do
              xml.tag! 'Version', MOBILE_API_VERSION, 'xmlns' => 'urn:ebay:apis:eBLBaseComponents'
              xml.tag! 'SetMobileCheckoutRequestDetails' ,'xmlns' => "urn:ebay:apis:eBLBaseComponents", 'xmlns:ebl' => "urn:ebay:apis:eBLBaseComponents", "xmlns:xsi" => "http://www.w3.org/2001/XMLSchema-instance", "xsi:type" => "ebl:SetMobileCheckoutRequestDetailsType" do 
                xml.tag! 'ReturnURL', options[:return_url]
                xml.tag! 'CancelURL', options[:cancel_return_url]
                xml.tag! 'BuyerPhone.PhoneNumber', options[:phone_number]
                xml.tag! 'InvoiceID', options[:order_id]
                xml.tag! 'ItemAmount', amount(money), 'currencyID' => currency_code
                xml.tag! 'ItemName', options[:description]
                xml.tag! 'ItemNumber', options[:item_names]
                xml.tag! 'BuyerEmail', options[:email] unless options[:email].blank?
              end
            end
          end

        else
          xml.tag! 'SetExpressCheckoutReq', 'xmlns' => PAYPAL_NAMESPACE do
            xml.tag! 'SetExpressCheckoutRequest', 'xmlns:n2' => EBAY_NAMESPACE do
              xml.tag! 'n2:Version', API_VERSION
              xml.tag! 'n2:SetExpressCheckoutRequestDetails' do
                # xml.tag! 'n2:OrderTotal', amount(money).to_f.zero? ? amount(100) : amount(money), 'currencyID' => options[:currency] || currency(money)
                xml.tag! 'n2:ReturnURL', options[:return_url]
                xml.tag! 'n2:CancelURL', options[:cancel_return_url]
                if options[:max_amount]
                  xml.tag! 'n2:MaxAmount', amount(options[:max_amount]), 'currencyID' => options[:currency] || currency(options[:max_amount])
                end
                xml.tag! 'n2:OrderDescription', options[:description]
                xml.tag! 'n2:InvoiceID', options[:order_id]
                xml.tag! 'n2:ReqConfirmShipping', 0
                xml.tag! 'n2:ReqBillingAddress', 0
                xml.tag! 'n2:NoShipping', options[:no_shipping] ? '1' : '0'
                xml.tag! 'n2:AddressOverride', options[:address_override] ? '1' : '0'
                xml.tag! 'n2:LocaleCode', options[:locale] unless options[:locale].blank?

                # Customization of the payment page
                xml.tag! 'n2:PageStyle', options[:page_style] unless options[:page_style].blank?
                xml.tag! 'n2:cpp-image-header', options[:header_image] unless options[:header_image].blank?
                xml.tag! 'n2:cpp-header-back-color', options[:header_background_color] unless options[:header_background_color].blank?
                xml.tag! 'n2:cpp-header-border-color', options[:header_border_color] unless options[:header_border_color].blank?
                xml.tag! 'n2:cpp-payflow-color', options[:background_color] unless options[:background_color].blank?

                add_address(xml, 'n2:Address', options[:shipping_address] || options[:address])


                xml.tag! 'n2:PaymentAction', action
                xml.tag! 'n2:SolutionType', 'Sole'
                xml.tag! 'n2:LandingPage', 'Login'
                xml.tag! 'n2:BuyerEmail', options[:email] unless options[:email].blank?


                currency_code = options[:currency] || currency(money)
                xml.tag! 'n2:PaymentDetails' do
                  xml.tag! 'n2:OrderTotal', amount(money), 'currencyID' => currency_code
                  xml.tag! 'n2:ItemTotal', amount(money), 'currencyID' => currency_code
                  xml.tag! 'n2:ShippingTotal', '0.00','currencyID' => currency_code
                  xml.tag! 'n2:HandlingTotal', '0.00','currencyID' => currency_code
                  xml.tag! 'n2:TaxTotal', '0.00', 'currencyID' => currency_code
                  # xml.tag! 'n2:PaymentAction', action
                  if options[:paymentDetailsItems]
                    options[:paymentDetailsItems].each do |paymentDetailItem|
                      xml.tag! 'n2:PaymentDetailsItem' do
                        xml.tag! 'n2:Name', paymentDetailItem[:name] if paymentDetailItem[:name]
                        xml.tag! 'n2:Number', paymentDetailItem[:number] if paymentDetailItem[:number]
                        xml.tag! 'n2:Quantity', paymentDetailItem[:quantity] if paymentDetailItem[:quantity]
                        xml.tag! 'n2:Amount', amount(paymentDetailItem[:amount]), 'currencyID' => currency_code if paymentDetailItem[:amount]
                        xml.tag! 'n2:Tax', amount(paymentDetailItem[:tax]), 'currencyID' => currency_code if paymentDetailItem[:tax]
                        xml.tag! 'n2:Description', paymentDetailItem[:description]
                      end
                    end
                  end
                  # xml.tag! 'n2:InvoiceID', options[:order_id]
                  # xml.tag! 'n2:OrderDescription', options[:description]
                  # xml.tag! 'n2:CurrencyCode', currency_code  
                end

              end
            end
          end
          
        end

        xml.target!
      end
      
      def build_response(success, message, response, options = {})
        PaypalExpressResponse.new(success, message, response, options)
      end
    end
  end
end
