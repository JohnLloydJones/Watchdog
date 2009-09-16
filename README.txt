Watchdog utility to check forum users against the online Stop Forum Spam database of Spammers.

This utility has been written to watch for Forum Spammers on a Rapidboards (http://www.rapidboards.com/)
free message board. The key issue with using a free message board, like Rapidboards, is a lack of access
to the underlying code. Without that, it is not possible to hook into the registration process to check
if a new user is a known forum spammer. This utility, which is intended to be run as a cron job, checks
for new users and when it finds them, sets them to require indefinite moderating (i.e. their posts will not
show up until a moderator/admin has reviewed them), emails a warning and reports the spammer back to the
Stop Forum Spammers site.

Configuration and use:
Note that the utility is intended for admins and may require some tweaking of the (Ruby) script.

Ensure that you have a working version of Ruby (tested on 1.8.7).
You will also need the following Ruby gems:
   crypt
   termios

The rapid.yaml file contains mmost of the configuration details. You will need to specify a user name and
password, an admin user name and password (which may or may not be the same as the first user). NOTE! The
passwords stored in the yaml file must be encrypted (using the provided encrypt_mail_password script provided).
Also in the yaml file are the email smtp host and email user and email (encrypted) password; a comma seperated
list of email addresses (this would typically be the admin and moderator users) and the Stop Forum Spam API key.

The script rapid.rb contains one configurable item: RAPID_BOARDS constant must be set the URL to your
rapidboards message board.

How to encrypt a password:
Run the encryption utility : ruby encrypt_mail_password.rb
At the prompt, enter the password (nothing is echoed) followed by enter.
Copy the generated password and paste it into the yaml file.

Testing
Run the utility : ruby rapid.rb
View the log file : E.g. tail -f rapid.log

If one of the 10 newest members is found to be a spammer, you will a comment in the log file
and an email should be sent to the listed email addresses. The last_user.dat file remembers the
last user checked, so to re-run while testing you need to edit the file and reset the last user
id to, for example, 0.

When testing is completed and you are satisfied things are working, use crontab schedule the watchdog
at suitable intervals.

How it works:

1) Log in as a forum user and get the 10 most recent memebers (i.e. list by Join Date, Descending order)
2) For each new user, get the member details (email and IP address) using the admin login.
3) Check to see if the new user is a known spammer using the Stop Forum Spam api
4) If the new user is a know spammer, edit the user's details to reqire indefinite moderating. Also
   send a warning email to the email addresses provided.

The interaction with the rapidboard site is done with straight Http requests and regular expression matching
of the response. It is possible -- though not very likely -- that the a different skin could upset the script
by breakng some of the assumptions hard-coded into the regular expressions. I have only test this against
the standard skin. 


