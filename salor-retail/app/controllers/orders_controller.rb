# coding: UTF-8

# Salor -- The innovative Point Of Sales Software for your Retail Store
# Copyright (C) 2012-2013  Red (E) Tools LTD
# 
# See license.txt for the license applying to all files within this software.


class OrdersController < ApplicationController

   respond_to :html, :xml, :json, :csv
   
   def undo_drawer_transaction
      @order = @current_vendor.orders.find_by_id(params[:oid].to_s)
      @dt = DrawerTransaction.find_by_id(params[:id].to_s)
      @drawer = @dt.drawer
      if @dt.order_id == @order.id then
        if @dt.drop then
          @drawer.update_attribute :amount, @drawer.amount - @dt.amount
        else
          @drawer.update_attribute :amount, @drawer.amount + @dt.amount
        end
        @dt.delete
        History.record("DTDeletedBy:#{@current_user.id}:#{@current_user.username}",@order,1,"orders_controller#undo_drawer_transaction");
        $Notice = "DT Deleted";
      end
      redirect_to "/orders/#{@order.id}" and return
   end

   
  def new_from_proforma
    @proforma = Order.scopied.find_by_id(params[:order_id].to_s)
    @order = @proforma.dup
    @order.save
    @order.reload
    @proforma.order_items.visible.each do |oi|
       noi = oi.dup
       noi.order_id = @order.id
       noi.save
    end
    item = Item.get_by_code("DMYACONTO")
    item.update_attribute :name, I18n.t("receipts.a_conto")
    item.make_valid
    @order.update_attribute :paid, 0
    noi = @order.add_item(item)
    noi.price = @proforma.amount_paid * -1
    noi.is_buyback = true
    noi.save
    @order.is_proforma = false

    redirect_to "/orders/new?order_id=#{@order.id}"
  end
  
  def merge_into_current_order
    @current = @current_vendor.orders.find_by_id(params[:order_id])
    @to_merge = @current_vendor.orders.find_by_id(params[:id])
    @to_merge.order_items.visible.each do |oi|
       noi = oi.dup
       noi.order_id = @current.id
       noi.save
    end

    redirect_to "/orders/new?order_id=#{@current.id}"
  end
  
  def index
    params[:type] ||= 'normal'
    case params[:type]
    when 'normal'
      @orders = @current_vendor.orders.order("nr desc").where(:paid => 1).page(params[:page]).per(25)
    when 'proforma'
      @orders = @current_vendor.orders.order("nr desc").where(:is_proforma => true).page(params[:page]).per(25)
    when 'unpaid'
      @orders = @current_vendor.orders.order("nr desc").unpaid.page(params[:page]).per(25)
    when 'quote'
      @orders = @current_vendor.orders.order("qnr desc").quotes.page(params[:page]).per(25)
    else
      @orders = @current_vendor.orders.order("id desc").page(params[:page]).per(25)
    end
    
    
    respond_with(@orders)
  end


  def show
    @order = @current_vendor.orders.visible.find_by_id(params[:id])
  end

  def new
    # need a cash register
    redirect_to cash_registers_path and return unless @current_register
    
    # get an order from params
    if params[:order_id].to_i != 0 then
      @current_order = @current_vendor.orders.where(:paid => nil).find_by_id(params[:order_id])
    end
    
    # get user's last order if unpaid
    unless @current_order
      @current_order = @current_vendor.orders.where(:paid => nil).find_by_id(@current_user.current_order_id)
    end
    
    # create new order if all of the previous fails
    unless @current_order
      @current_order = Order.new
      @current_order.vendor = @current_vendor
      @current_order.company = @current_company
      @current_order.user = @current_user
      @current_order.cash_register = @current_register
      @current_order.drawer = @currrent_user.get_drawer
      @current_order.save
      @current_user.current_order_id = @current_order.id
      @current_user.save
    end

    # push notification to refresh the customer screen
    t = SalorRetail.tailor
    if t
      t.puts "CUSTOMERSCREENEVENT|#{@current_vendor.hash_id}|#{ @current_register.name }|#{ request.protocol }#{ request.host }:#{ request.port }/orders/#{ @current_order.id }/customer_display"
    end
 
    @button_categories = Category.where(:button_category => true).order(:position)
    
    CashRegister.update_all_devicenodes
    @current_register.reload
  end


  def edit
    @current_user.current_order_id = params[:id]
    @current_user.save
    redirect_to new_order_path
  end


  def add_item_ajax
    @order = @current_vendor.orders.where(:paid => nil).find_by_id(params[:order_id])
    
    @order_item = @order.add_order_item(params)
    
    # --- push notification to refresh the customer screen
    t = SalorRetail.tailor
    if t
      t.puts "CUSTOMERSCREENEVENT|#{@current_vendor.hash_id}|#{ @current_register.name }|#{ request.protocol }#{ request.host }:#{ request.port }/orders/#{ @order.id }/customer_display"
    end
    # ---
  end


  def delete_order_item
    oi = @current_vendor.order_items.find_by_id(params[:id])
    @order = oi.order
    @order.remove_order_item(oi)
    
    # --- push notification to refresh the customer screen
    t = SalorRetail.tailor
    if t and @order
      t.puts "CUSTOMERSCREENEVENT|#{@current_vendor.hash_id}|#{ @order.cash_register.name }|#{ request.protocol }#{ request.host }:#{ request.port }/orders/#{ @order.id }/customer_display"
    end
    # ---
  end

  def print_receipt
    @user = User.find_by_id(params[:user_id])
    @register = CashRegister.find_by_id(params[:current_register_id])
    if @register then
      @vendor = @register.vendor 
    end
    
    render :nothing => true and return if @register.nil? or @vendor.nil? or @user.nil?

    @order = Order.find_by_id(params[:order_id])
    if not @order then
      render :text => "No Order Found" and return
    end
    
    if @register.salor_printer
      @report = @order.get_report
      contents = @order.escpos_receipt(@report)
      output = Escper::Printer.merge_texts(contents[:text], contents[:raw_insertations])
      if params[:download] then
        send_data(output, {:filename => 'salor.bill'})
      else
        render :text => output and return
      end
    else
      if is_mac? then
        @report = @order.get_report
        contents = @order.escpos_receipt(@report)
        output = Escper::Printer.merge_texts(contents[:text], contents[:raw_insertations])
        File.open("/tmp/" + @register.thermal_printer,'wb') { |f| f.write output }
        `lp -d #{@register.thermal_printer} /tmp/#{@register.thermal_printer}`
        render :nothing => true and return
      else
        @order.print
      end
      render :nothing => true and return
    end
  end

  # due to a report of a client, just rendering the template is not enough for putting "copy/duplicate" on the receipt. so, let salor-bin confirm if bytes were actually sent to a file.
  def print_confirmed
    o = Order.find_by_id params[:order_id]
    
    o.update_attribute :was_printed, true if o
    render :nothing => true
  end


  def show_payment_ajax
    @order = @current_vendor.orders.where(:paid => nil).find_by_id(params[:order_id])
    #@order.calculate_totals(false)
    #@order.save!
  end
  
  def last_five_orders
    @text = render_to_string('shared/_last_five_orders',:layout => false)
    render :text => @text
  end
  def bancomat
    if params[:msg] then
        nm = JSON.parse(params[:msg]) 
        @p = PaylifeStructs.new(:sa => nm['sa'],:ind => nm['ind'],:struct => CGI::unescape(nm['msg']), :json => params[:msg])
        if not @p.save then
          render :text => "alert('Saving Struct Failed!!');" and return
        end
    end
    render :nothing => true
  end
  
  def complete_order_ajax
    @order = @current_vendor.orders.where(:paid => nil).find_by_id(params[:order_id])
    
    SalorBase.log_action("OrdersController","complete_order_ajax order initialized")
    History.record("initialized order for complete",@order,5)

    if params[:user_id] and params[:user_id] != @current_user.id then
      tmp_user = User.find_by_id(params[:user_id])
      if tmp_user and tmp_user.vendor_id == @current_user.vendor_id then
        tmp_user.update_attribute :current_register_id, @current_register
        History.record("swapped user #{@current_user.id} with #{tmp_user.id}",@order,3)
        @current_user = tmp_user
        @order.update_attribute :user_id, @current_user.id
        SalorBase.log_action("OrdersController","tmp_user swapped")
      else
        SalorBase.log_action("OrdersController","tmp_user does not belong to this store")
        render :js => "alert('InCorrectUser');"
      end
    end
    

    @order.payment_methods.delete_all
    SalorBase.log_action("OrdersController","payment methods on order removed")
    
    if @order.total > 0 or @order.order_items.visible.any? and not GlobalErrors.any_fatal? then
      payment_methods_array = [] # We need to do some checks on the payment
      # methods, so we put them into an array before saving them and the order
      # This is kind of a validator, but we need to do it here for right now...
      payment_methods_total = 0.0
      payment_methods_seen = [] # In case they use the same internal type for two different payment_methods.
      
      @current_vendor.payment_methods_types_list.each do |pmt|
        pt = pmt[1]
        next if payment_methods_seen.include? pt
        payment_methods_seen << pt
        if params[pt.to_sym] and not params[pt.to_sym].blank? and not SalorBase.string_to_float(params[pt.to_sym]) == 0 then
          if pt == 'Unpaid' then
            @order.update_attribute :unpaid_invoice, true # to support finishing invoices early so that they are inline, even though they haven't been paid yet
          end
          if pt == 'Quote'
            @order.update_attribute :is_quote, true
          end
          pm = PaymentMethod.new
          pm.name = pmt[0]
          pm.internal_type = pt
          pm.amount = SalorBase.string_to_float(params[pt.to_sym])
          pm.vendor = @current_vendor

          if pm.amount > @order.total then
            # puts  "## Entering Sanity Check"
            sanity_check = pm.amount - @order.total
            # puts  "#{sanity_check}"
            if sanity_check > 500 then
              GlobalErrors.append_fatal("system.errors.sanity_check")
              $Notice = "Sanity Check 1 Failed"
              History.record("Sanity Check 1 Failed: #{sanity_check} > 500",@order,5)
              render :action => :update_pos_display and return
            end
          end
          payment_methods_total += pm.amount
          pm.order_id = @order.id
          payment_methods_array << pm
        end
      end
      # FIXME: Payment methods should be put on the order, and then saved, otherwise they are not present
      # for get_drawer_add. THis is fixed by a reload for the time being.
      # @order.payment_methods = mayment_methods_array
      # Now we check the payment_methods_total to make sure that it matches
      # what we think the order.total should be
      @order.reload
      
      if payment_methods_total.round(2) < @order.total.round(2) and @order.is_proforma == false then
        GlobalErrors.append_fatal("system.errors.sanity_check")
        log_action "Sanity Check 2 Failed: #{payment_methods_total.round(2)} < #{@order.total.round(2)} and #{@order.is_proforma == false}"
        History.record("Sanity Check 2 Failed: #{payment_methods_total.round(2)} < #{@order.total.round(2)} and #{@order.is_proforma == false}",@order,5);
        $Notice = "Sanity Check 2 Failed: #{payment_methods_total.round(2)} < #{@order.total.round(2)} and #{@order.is_proforma == false}"
        SalorBase.log_action("OrdersController","Failed sanity_check")
        # update_pos_display should update the interface to show
        # the correct total, this was the bug found by CigarMan
        render :action => :update_pos_display and return
      else
        payment_methods_array.each {|pm| pm.save } # otherwise, we save them
      end
      
      SalorBase.log_action("OrdersController","payment_methods saved")
      if @order.is_proforma == true then
        History.record("Order is proforma, completing",@order,5)
        @order.complete
        render :js => " window.location = '/orders/#{@order.id}/print'; " and return
      end
      params[:print].nil? ? print = 'true' : print = params[:print].to_s

      @order.complete
      SalorBase.log_action("OrdersController","@order.complete called")
      
      # --- push notification to refresh the customer screen
      t = SalorRetail.tailor
      if t
        t.puts "CUSTOMERSCREENEVENT|#{@current_vendor.hash_id}|#{ @order.cash_register.name }|#{ request.protocol }#{ request.host }:#{ request.port }/orders/#{ @order.id }/customer_display?display_change=1"
      end
      # ---
     
      @old_order = @order
      
      o = Order.new
      o.vendor = @current_vendor
      o.user = @current_user
      o.cash_register = @current_register
      o.save
      @current_user.current_order_id = o.id
      @current_user.save
    end
  end
  
  def new_order
    o = Order.new
    o.vendor = @current_vendor
    o.company = @current_company
    o.user = @current_user
    o.drawer = @current_user.get_drawer
    o.cash_register = @current_register
    o.save
    @current_user.current_order_id = o.id
    @current_user.save
    redirect_to new_order_path
  end
  
  def activate_gift_card
    @error = nil
    @order = initialize_order
    @order_item = @order.activate_gift_card(params[:id],params[:amount])
    if not @order_item then
      History.record("Failed to activate gift card",@order,5)
      @error = true
    else
      History.record("Activated Gift Card #{@order_item.sku}",@order,5)
      @item = @order_item.item
    end
    @order.reload

  end
  def update_order_items
    @order = initialize_order
  end
  
  def update_pos_display
    @order = initialize_order
    if @order.paid == 1 and not @current_user.is_technician? then
      @order = @current_user.get_new_order
    end
  end
  
  def split_order_item
    @oi = OrderItem.find_by_id(params[:id].to_s)
    restore_paid = false
    if @oi then
      @order = @oi.order
      History.record("Splitting items on order",@order,5)
      noi = @oi.dup
      if @order.paid == 1 then
        @order.paid = 0
        @oi.order.paid = 0
        noi.order.paid = 0
        restore_paid = true
      end
      @oi.quantity = @oi.quantity - 1
      @oi.save!
      noi.update_attribute :quantity, 1
      noi.save!

      if restore_paid then
        History.record("Restored paid on Order",@order,1)
        @order.paid = 1
        @order.save
      end
    end
    redirect_to "/orders/#{@oi.order.id}"
  end
  
  def refund_item
    @oi = @current_vendor.order_items.visible.find_by_id(params[:id])
    x = @oi.toggle_refund(true, params[:pm], @current_user)
    if x == -1 then
      flash[:notice] = I18n.t("system.errors.not_enough_in_drawer")
    end
    if x == false then
      flash[:notice] = I18n.t("system.errors.unspecified_error")
    end
    @oi.save
    redirect_to request.referer
  end
  
  def refund_order
    @order = Order.scopied.find_by_id(params[:id].to_s)
    @order.toggle_refund(true, params[:pm])
    @order.save
    redirect_to order_path(@order)
  end
  
  def customer_display
    @order = Order.find_by_id(params[:id].to_s)
    @current_user = @order.get_user
    @current_user = @order.get_user
    @vendor = Vendor.find(@order.vendor_id)
    $Conf = @vendor.salor_configuration
    @order_items = @order.order_items.visible.order('id ASC')
    @report = @order.get_report
    render :layout => 'customer_display'
  end

  def report
    f, t = assign_from_to(params)
    @from = f
    @to = t
    from2 = @from.beginning_of_day
    to2 = @to.beginning_of_day + 1.day
    @orders = Order.scopied.find(:all, :conditions => { :created_at => from2..to2, :paid => true })
    @orders.reverse!
    @taxes = TaxProfile.scopied.where( :hidden => 0)
  end

  def report_range
    #@from, @to = assign_from_to(params)
    #from2 = @from.beginning_of_day
    #to2 = @to.beginning_of_day + 1.day
    #@orders = Order.scopied.find(:all, :conditions => { :created_at => from2..to2, :paid => true })
    #@orders.reverse!
    #@taxes = TaxProfile.scopied.where( :hidden => 0)
    f, t = assign_from_to(params)
    @from = f
    @to = t
    @from = @from.beginning_of_day
    @to = @to.end_of_day
    @vendor = GlobalData.vendor
    @report = UserUserMethods.get_end_of_day_report(@from,@to,nil)
  end

  def report_day
    @from, @to = assign_from_to(params)
    @from = @from ? @from.beginning_of_day : DateTime.now.beginning_of_day
    @to = @to ? @to.end_of_day : @from.end_of_day
    @vendor = GlobalData.vendor
    @users = @vendor.users.where(:hidden => 0)
    @user = User.scopied.find_by_id(params[:user_id])
    @report = UserUserMethods.get_end_of_day_report(@from,@to,@user)
  end

  def report_day_range
    f, t = assign_from_to(params)
    @from = f
    @to = t
    from2 = @from.beginning_of_day
    to2 = @to.beginning_of_day + 1.day
    @taxes = TaxProfile.scopied.where( :hidden => 0)
  end
  
  def receipts
    @from, @to = assign_from_to(params)
    @from = @from ? @from.beginning_of_day : DateTime.now.beginning_of_day
    @to = @to ? @to.end_of_day : @from.end_of_day
    @receipts = @current_vendor.receipts.where(["created_at between ? and ?", @from, @to])
    if params[:print] == "true" and params[:current_register_id] then
      @current_register = @current_vendor.current_registers.find_by_id(params[:current_register_id].to_s)
      vendor_printer = VendorPrinter.new :path => @current_register.thermal_printer
      print_engine = Escper::Printer.new('local', vendor_printer)
      print_engine.open
      
      @receipts.each do |r|
        contents = r.content
        bytes_written, content_written = print_engine.print(0, contents)
      end
      print_engine.close
    end
  end
  
  def print
    @order = @current_vendor.orders.visible.find_by_id(params[:id])
    # @order.run_new_sanitization # Mikey: moved this into the model. doesn't make much sense to me to fix the order here when it simply should show the print page.
    @report = @order.get_report
    @invoice_note = @current_vendor.invoice_notes.visible.where(
      :origin_country_id => @order.origin_country_id, 
      :destination_country_id => @order.destination_country_id, 
      :sale_type_id => @order.sale_type_id
    ).first
    
    locale = params[:locale]
    locale ||= I18n.locale
    if locale
      tmp = InvoiceBlurb.where(:lang =>locale, :vendor_id => @current_user.vendor_id, :is_header => true)
      if tmp.first then
        @invoice_blurb_header = tmp.first.body
      end
      tmp = InvoiceBlurb.where(:lang => locale, :vendor_id => @current_user.vendor_id).where('is_header IS NOT TRUE')
      if tmp.first then
        @invoice_blurb_footer = tmp.first.body
      end
    end
    
    @invoice_blurb_header ||= @current_vendor.invoice_blurb
    @invoice_blurb_footer ||= @current_vendor.invoice_blurb_footer
    
    
    view = SalorRetail::Application::CONFIGURATION[:invoice_style]
    view ||= 'default'
    render "orders/invoices/#{view}/page"
  end
  
  def order_reports
    f, t = assign_from_to(params)
    @from = f
    @to = t
    params[:limit] ||= 15
    @limit = params[:limit].to_i - 1
    
    
    @orders = Order.scopied.where({:paid => 1, :created_at => @from..@to})
    
    @reports = {
        :items => {},
        :categories => {},
        :locations => {}
    }
    @orders.each do |o|
      o.order_items.visible.each do |oi|
        next if oi.item.nil?
        key = oi.item.name + " (#{oi.price})"
        cat_key = oi.get_category_name
        loc_key = oi.get_location_name
        
        @reports[:items][key] ||= {:sku => '', :quantity_sold => 0.0, :cash_made => 0.0 }
        @reports[:items][key][:quantity_sold] += oi.quantity
        @reports[:items][key][:cash_made] += oi.total
        @reports[:items][key][:sku] = oi.sku
        
        @reports[:categories][cat_key] ||= { :quantity_sold => 0.0, :cash_made => 0.0 }
        
        @reports[:categories][cat_key][:quantity_sold] += oi.quantity
        @reports[:categories][cat_key][:cash_made] += oi.total
        
        @reports[:locations][loc_key] ||= { :quantity_sold => 0.0, :cash_made => 0.0 }
        
        @reports[:locations][loc_key][:quantity_sold] += oi.quantity
        @reports[:locations][loc_key][:cash_made] += oi.total
      end
    end
    
    
    
    @categories_by_cash_made = @reports[:categories].sort_by { |k,v| v[:cash_made] }
    @categories_by_quantity_sold = @reports[:categories].sort_by { |k,v| v[:quantity_sold] }
    @locations_by_cash_made = @reports[:locations].sort_by { |k,v| v[:cash_made] }
    @locations_by_quantity_sold = @reports[:locations].sort_by { |k,v| v[:quantity_sold] }
    @items = @reports[:items].sort_by { |k,v| v[:quantity_sold] }
    
    view = SalorRetail::Application::CONFIGURATION[:reports][:style]
    view ||= 'default'
    render "orders/reports/#{view}/page"
  end
  #
  def remove_payment_method
    if @current_user.is_technician? then
      @order = Order.find(params[:id].to_s)
      if @order then
        @order.payment_methods.find(params[:pid]).destroy
      end
    end
  end
  
  def clear
    if not @current_user.can(:clear_orders) then
      History.record(:failed_to_clear,@order,1)
      GlobalErrors.append_fatal("system.errors.no_role",@order,{})
      render 'update_pos_display' and return
    end
    
    @order = @current_vendor.orders.where(:paid => nil).find_by_id(params[:order_id])
    
    if @order then
      History.record("Destroying #{@order.order_items.visible} items",@order,1)
      
      @order.order_items.visible.each do |oi|
        oi.hidden = 1
        oi.hidden_by = @current_user.id
        oi.save
      end
      
      @order.customer_id = nil
      @order.tag = nil
      @order.subtotal = 0
      @order.total = 0
      @order.tax = 0

    else
      History.record("cannot clear order because already paid", @order, 1)
      GlobalErrors.append_fatal("cannot clear order because already paid", @order, {})
    end
    render 'update_pos_display' and return
  end
  
  def log
    h = History.new
    h.url = "/orders/log"
    h.params = params
    h.model_id = params[:order_id]
    h.model_type = 'Order'
    h.action_taken = params[:log_action]
    h.changes_made = params[:called_from]
    h.save
    render :nothing => true
    # just to log into the production.log
  end

  private
 
  
  def currency(number,options={})
    options.symbolize_keys!
    defaults  = I18n.translate(:'number.format', :locale => options[:locale], :default => {})
    currency  = I18n.translate(:'number.currency.format', :locale => options[:locale], :default => {})
    defaults[:negative_format] = "-" + options[:format] if options[:format]
    options   = defaults.merge!(options)
    unit      = I18n.t("number.currency.format.unit")
    format    = I18n.t("number.currency.format.format")
    # puts  "Format is: " + format
    if number.to_f < 0
      format = options.delete(:negative_format)
      number = number.respond_to?("abs") ? number.abs : number.sub(/^-/, '')
    end
    value = number_with_precision(number)
    # puts  "value is " + value
    format.gsub(/%n/, value).gsub(/%u/, unit)
  end
  def number_with_precision(number, options = {})
    options.symbolize_keys!

    number = begin
      Float(number)
    rescue ArgumentError, TypeError
      if options[:raise]
        raise InvalidNumberError, number
      else
        return number
      end
    end

    defaults           = I18n.translate(:'number.format', :locale => options[:locale], :default => {})
    precision_defaults = I18n.translate(:'number.precision.format', :locale => options[:locale], :default => {})
    defaults           = defaults.merge(precision_defaults)

    options = options.reverse_merge(defaults)  # Allow the user to unset default values: Eg.: :significant => false
    precision = 2
    significant = options.delete :significant
    strip_insignificant_zeros = options.delete :strip_insignificant_zeros

    if significant and precision > 0
      if number == 0
        digits, rounded_number = 1, 0
      else
        digits = (Math.log10(number.abs) + 1).floor
        rounded_number = (BigDecimal.new(number.to_s) / BigDecimal.new((10 ** (digits - precision)).to_f.to_s)).round.to_f * 10 ** (digits - precision)
        digits = (Math.log10(rounded_number.abs) + 1).floor # After rounding, the number of digits may have changed
      end
      precision = precision - digits
      precision = precision > 0 ? precision : 0  #don't let it be negative
    else
      rounded_number = BigDecimal.new(number.to_s).round(precision).to_f
    end
    formatted_number = number_with_delimiter("%01.#{precision}f" % rounded_number, options)
    return formatted_number
  end
  def number_with_delimiter(number, options = {})
    options.symbolize_keys!

    begin
      Float(number)
    rescue ArgumentError, TypeError
      if options[:raise]
        raise InvalidNumberError, number
      else
        return number
      end
    end

    defaults = I18n.translate(:'number.format', :locale => options[:locale], :default => {})
    options = options.reverse_merge(defaults)

    parts = number.to_s.split('.')
    parts[0].gsub!(/(\d)(?=(\d\d\d)+(?!\d))/, "\\1#{options[:delimiter]}")
    return parts.join(options[:separator])
  end
  # {END}
end
