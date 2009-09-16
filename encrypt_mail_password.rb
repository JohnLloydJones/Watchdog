require 'rubygems'
require 'termios'
require 'encrypt.rb'

# Depends on termios (sudo gem install termios) for safe password entry.
# On Windows, use cygwin.

class Mail
   include Encrypt
   include Termios

   def noecho
      @old_t = getattr($stdin)
      new_t = @old_t.dup
      new_t.c_lflag &= ~ECHO
      setattr($stdin, TCSANOW, new_t)
   end
   
   def restore_echo
      setattr($stdin, TCSANOW, @old_t)
   end
   
   def encrypt_password
      print "Enter password: ";  $stdout.flush
      noecho
      pwd = encrypt( $stdin.sysread(32).strip )
      puts "\nEncrypted: #{ pwd }"
   ensure
      restore_echo
   end
end

if $0 == __FILE__
   puts "encrypt_mail_password: "
   app = Mail.new
   app.encrypt_password
end