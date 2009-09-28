require 'rubygems'
require 'net/http'
require 'uri'
require 'logger'
$LOAD_PATH << File.dirname(__FILE__)
require 'sendmail.rb'

RAPID_BOARDS = 'bc-rescue.rapidboards.com'
STOP_FORUM_SPAM = 'www.stopforumspam.com'
STATIC_PATH = File.dirname(__FILE__)
LAST_USER_FILE = File.join(STATIC_PATH, 'last_user.dat')
YAML_FILE = File.join( STATIC_PATH,'rapid.yaml' )
USERS_FILE = File.join( STATIC_PATH,'users.yaml' )
LOG_FILE = File.join( STATIC_PATH,'rapid.log' )


class User
   attr_accessor :uid, :name, :email, :ip, :status
   
   def initialize( uid, name, status )
      @uid = uid
      @name = name
      @status = status
   end
   
   def spammer?
      RapidBoard::check_sfs self
   end
end

class RapidBoard
   include Encrypt

   EMAIL_END = <<-END_OF_TEXT
   Moderators:
   If you see this user has posted to the board, please check the content and delete if required.
   
   Admins:
   Please verify that this user is actually a spammer (e.g. at http://www.stopforumspam.com/) and delete the user if required.
   
   This email was generated automatically by the BCRB watchdog script.
   
   Thank you.
END_OF_TEXT

   def initialize
      begin
         @properties = YAML::load( File.open( YAML_FILE ) )
         @known_users = YAML::load( File.open( USERS_FILE ) )

      rescue
         puts "Yaml not found!"
         exit
      end
      
      @emailprops = {}
      @properties.each { |key, value| @emailprops[key] = value if key =~ /^email/ }
      @emailprops['emailport'] ||= '25'
      @emailprops['emailrecipients'] = @emailprops['emailrecipients'].split(',') || "#{@emailprops['emailuser']}@#{@emailprops['emailhost']}"
      
      @log = Logger.new( LOG_FILE )
      @log.level = Logger::INFO
      @log.info "Watchdog starting..."
   end
   
   def self.check_sfs( user )
      check_sfs_item('email', user.email) || check_sfs_item('ip', user.ip)
   end

   def self.check_sfs_item(name, value)
      Net::HTTP.start(STOP_FORUM_SPAM) do |http|
         response = http.get("/api?#{name}=#{value}")
         raise "SFS error" unless response.body =~ /success="true"/
         return response.body =~ /<appears>yes<\/appears>/
      end
   end

   #get the index page and initial session_id token.
   def index
      Net::HTTP.start(RAPID_BOARDS) do |http|
         response = http.get('/index.php')
         case response
            when Net::HTTPSuccess
               cookies = parse_cookies response['set-cookie']
               @member_id =  cookies['member_id']
               @session_id = cookies['session_id']
               @pass_hash =  cookies['pass_hash']
         else
            @log.error "/index.php response was #{response.code}: #{response.message}"
            exit
         end
      end
   end

   # Do a normal login and save the session_id cookie.
   def login
      cookies = "pass_hash=0; member_id=0; session_id=#{@session_id}"
      headers = {'Cookie'=>"#{cookies}", 'Content-Type'=>'application/x-www-form-urlencoded'}
      Net::HTTP.start(RAPID_BOARDS) do |http|
         response = http.post('/index.php?act=Login&CODE=01&CookieDate=1',
                              "UserName=#{@properties['username']}&PassWord=#{decrypt(@properties['userpassword'])}",
                              headers)
         cookies = parse_cookies response['set-cookie']
      
         @member_id =  cookies['member_id'].to_s
         @session_id = cookies['session_id']
         @pass_hash =  cookies['pass_hash']
         
         @log.error "Login failed!" if (@member_id.nil? || @member_id == '0')
      end
      
   end
   # Log in to the admin console and save the adsess login token.
   def admin_login
      headers = {'Content-Type'=>'application/x-www-form-urlencoded'}
      Net::HTTP.start(RAPID_BOARDS) do |http|
         response = http.post('/admin.php',
                              "adsess=&login=yes&username=#{@properties['adminuser']}&password=#{decrypt(@properties['adminpassword'])}",
                              headers)
         @adsess = /adsess=([0-9a-f]*)'/.match(response.body)[1]
      end
   rescue Exception => e
       @log.error "admin_login failed.\n#{e}"
       exit
   end

   # Using a normal login, get the 10 most recent members, sorted by descending joind date. In reverse order,
   # check to see if they are new, ans if so, look to see if they are a known spammer. Users identified
   # as spammers are edited (to require moderating), an email warning gets sent out and the incident is reported back to SFS.
   def get_new_members
      index
      login if @member_id.nil?
      exit if @member_id.nil? || @member_id == '0'
      @known_users_changed = false
      
      cookies = "pass_hash=#{@pass_hash}; member_id=#{@member_id}; session_id=#{@session_id}"
      headers = {'Cookie'=>"#{cookies}", 'Content-Type'=>'application/x-www-form-urlencoded'}
      Net::HTTP.start(RAPID_BOARDS) do |http|
         response = http.post('/index.php?',
                   "act=Members&s=&name_box=all&name=&filter=ALL&sort_key=joined&sort_order=desc&max_results=10",
                   headers)
         
         get_member_details response.body

#         uid = get_last_user
         uid = @known_users[-1].uid
         
         @users.each do |user|
            puts "looking at user #{user.name}(#{user.uid}) compared to last known user #{@known_users[-1].name}(#{uid})"
            break if (uid.to_i < user.uid.to_i)
            break if (uid.to_i == user.uid.to_i) && (user.name == @know_users[uid.to_i].name) # same id && same name
            @log.info "User #{@known_users[uid.to_i].name} has been deleted, removing from user list"
            @known_users.delete_at( -1 )
            uid = @known_users[-1].uid
            @known_users_changed = true
         end
         
         @users.reverse_each do |user|
            begin
               puts "Looking at #{user.name}"
               if user.uid.to_i > uid.to_i
                  @log.info "new: find member #{user.name}(#{user.uid})..."
                  user = find_member user
                  @known_users[user.uid.to_i] = user
                  @log.info "#{user.name}(#{user.uid}), email: #{user.email}, ip: #{user.ip}"
                  if user.spammer?
                     @log.info "!  #{user.name} is a known spammer!"
                     emailbody =<<END_OF_BODY
   Border Collie Rescue Boards: Spammer Alert !
   The newly registered user #{user.name} has been identified to be a forum spammer! Please take the following action:

END_OF_BODY
                     emailbody << EMAIL_END
                     @emailprops['emailbody'] = emailbody
                     sm = SendMail.new( @emailprops['emailhost'], @emailprops['emailport'] )
                     sm.send_email( @emailprops, "#{@emailprops['emailuser']}@#{@emailprops['emailhost']}", "Admins and Moderators", 'Spammer Alert' )

                     edit user # set indefinite moderating
                     report_spammer user
                  end
                  uid = user.uid
                  set_last_user uid
                  @known_users_changed = true
               end
            rescue Exception => e
               puts "Oops:\n #{e}"
               @log.error "Check for #{user.name} failed !\n#{$!}\n#{e.backtrace.join("\n")}"
            end
         end
      end
      File.open( USERS_FILE, 'w' ) {|f| YAML.dump(@known_users, f) } if @known_users_changed
   end

   # Uses admin privileges to get email address and IP address for the user
   def find_member user
     admin_login if @adsess.nil?

      headers = {'Content-Type'=>'application/x-www-form-urlencoded'}
      Net::HTTP.start(RAPID_BOARDS) do |http|
         response = http.post("/admin.php?adsess=#{@adsess}",
                              "adsess=#{@adsess}&code=stepone&act=mem&USER_NAME=#{user.name}",
                              headers)
         case response
         when Net::HTTPSuccess
            m = />\d+ Search Results<\/div>(.*?)<\/div>/m.match(response.body)
            if m.nil? || m.size < 2
               @log.warn "Member lookup failed for #{user.name}"
               break
            end
            table = m[1]
            r = /<tr>(.*?)<\/tr>/mi
            s = table
            loop do
               m = r.match( s )
               break if m.nil?
               row = m[1]
               m2 = />(\d+\.\d+\.\d+\.\d+)<.*>(.+?@.+?)</mi.match( row )
               user.ip, user.email = m2[1], m2[2] if m2
               s = m.post_match
            end
         else
            @log.error "find member response was #{response.code}: #{response.message}"
            exit
         end
      end
      user
   end

   # Get the current user details and then set the user to require indefinite moderating. 
   def edit user
      headers = {'Content-Type'=>'application/x-www-form-urlencoded'}
      
      r = /name='curpass' value='([0-9a-f]*)'/
      grp = /<select name='mgroup'.*?<option value='(\d)' selected>\w*?<\/option>/m
      Net::HTTP.start(RAPID_BOARDS) do |http|
         response = http.get("/admin.php?adsess=#{@adsess}&act=mem&code=doform&MEMBER_ID=#{user.uid}")
         m = r.match( response.body )
         @curpass = m[1]
         m2 = grp.match( response.body )
         @mgroup = m2 ? m2[1] : "3";
         
      end
      
      #      puts "curpass = #{@curpass}"
      Net::HTTP.start(RAPID_BOARDS) do |http|
         response = http.post("/admin.php?adsess=#{@adsess}",
                              "adsess=#{@adsess}&code=doedit&act=mem&mid=#{user.uid}&curpass=#{@curpass}&email=#{user.email}&mod_indef=1&mgroup=#{@mgroup}",
                              headers)
         case response
         when Net::HTTPSuccess
            @log.info "OK: user #{user.name} edited to have indefinite moderating."
         else
            @log.error "user edit response was #{response.code}: #{response.message}"
            exit
         end
      end
   end
   # User the SFS API to report this spammer. 
   def report_spammer user
      Net::HTTP.start(STOP_FORUM_SPAM) do |http|
         response = http.post("/add","api_key=#{@properties['api_key']}&username=#{URI.escape(user.name)}&ip_addr=#{user.ip}&email=#{URI.escape(user.email)}")
         case response
         when Net::HTTPSuccess
            @log.info "OK, reported."
         else
            @log.error "report spammer response was #{response.code}: #{response.message}"
         end
      end
   rescue Exeception => e
      @log.error "sfs post failed.\n #{$!}"
   end
   
   def get_last_user
      uid = File.open(LAST_USER_FILE) {|f| f.read(nil)} rescue 0
   end
   
   def set_last_user uid
      @log.info "set_last_user: #{uid}"
      File.open(LAST_USER_FILE, 'w') {|f| f.write(uid)}
   end
   
   # Get the member details from the Member List screen
   def get_member_details html
      @users = []
      table = /<div class="maintitle">Member List<\/div>(.*?)<\/div>/m.match(html)[1]
      r = /<tr>(.*?)<\/tr>/mi
      s = table
      loop do
         m = r.match( s )
         break if m.nil? || m.size < 2
         row = m[1]
         m2 = /showuser=(\d*)">(.*?)<\/a>/.match( row )
         if m2
            name = m2[2]
            uid = m2[1]
            e = /&#(.*?);/.match(name)
            if ! e.nil? && e.size > 1
               name = e.pre_match << e[1].to_i << e.post_match
            end
            m3 = /class='row2' align="center" width="20%">(\w*?)<\/td>/.match( row )
            @users << User.new( uid, name, m3[1] )
         end
         s = m.post_match
      end
   end
   # This isn't pretty, but it is good enough for extractig the session id.
   def parse_cookies string
      c = {}
      a = string.split(/[;,] */)
      a.each {|o| v=o.split('=',2); c[v[0]]=(v[1])}
      c
   end
end

if __FILE__ == $0
   begin
      app = RapidBoard.new
      app.get_new_members
   rescue Exception => e
      puts "Failed: \n#{$!}\n#{e.backtrace.join("\n")}"
   end
end
