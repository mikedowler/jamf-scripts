#!/bin/zsh

#########################################################################################
# This script will provide temporary admin rights to a standard user right from self    #
# service.                                                                              #
# It will grab the username of the logged in user, and create a file with a timestamp   #
# for when the rights should end. It will then create and load a launchdaemon and       #
# corresponding script; the LD runs the script every 5 mins to check whether the        #
# timestamp has passed (or the file is missing). If so, the script will demote the user #
# back to a Standard User.                                                              #
# The LaunchDaemon will keep running, regardless of any restarts, until the script      #
# completes. At that point, the LaunchDaemon will be unloaded and deleted.              #
#########################################################################################

####################################
#         General settings         #
####################################

slackWebhookUrl="${4}"
elevationHours=${5}      # integer number of hours to elevate for
elevationMinutes=${6}    # integer number of minutes to elevate for

# e.g alan.partridge
currentUser=$( /usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | /usr/bin/awk '/Name :/ && ! /loginwindow/ {print $3}' )

# Path to the LaunchDaemon plist
launchDaemonLabel="removeAdmin-${currentUser}"
launchDaemonPath="/Library/LaunchDaemons/${launchDaemonLabel}.plist"

# Path to store elevation timestamps
timeStampPath="/private/var/MakeMeAdmin-${currentUser}"

####################################################
#      Check if the user is already an admin       #
####################################################

isAdmin=$( /usr/sbin/dseditgroup -o checkmember -m "${currentUser}" admin | /usr/bin/awk '{print $1}' )

if [[ ${isAdmin} == *"yes"* ]]; then
	echo "User is already an admin.  Exiting..."
	/usr/bin/osascript -e 'display dialog "You are already an admin."'
    exit 0
fi

####################################
#         Legacy check             #
####################################
# Remove the old LaunchDaemon, if it exists
if /bin/launchctl list | /usr/bin/grep "removeAdmin$" >/dev/null; then
	/bin/launchctl bootout system/removeAdmin
fi
if [[ -f /Library/LaunchDaemons/removeAdmin.plist ]]; then
	/bin/rm -f /Library/LaunchDaemons/removeAdmin.plist
fi

#############################################
#            Display the T&C's              #
#############################################

/usr/bin/osascript -e 'set termsAndConditions to "You are about to assume local admin credentials on this machine.

Proceed with caution and ensure that you are using these credentials only for the purpose stated in your justification.

Any intentional actions other than for the purpose granted will constitute misconduct and may result in disciplinary action against you."

display dialog termsAndConditions with title "Terms and Conditions" buttons {"Reject","Confirm"} default button "Confirm" cancel button "Reject"
set response to button returned of the result

if (response is "Reject") then
  display dialog "Request cancelled" buttons {"OK"}
end if' || exit 1


#############################################
#          Display justification box        #
#############################################

justification=""

# We loop until either the user successfully supplies a justification, or they cancel
for (( ; ; )); do
    justification=$( /usr/bin/osascript -e '
    try
    display dialog "Please describe why you need local admin rights?

    Link the JIRA ticket if admin is required for a specific task.

    *minimum 10 characters*

    " default answer "" with title "Justification" 
    set the userJustification to text returned of the result
    return userJustification

    -- Error handling
    on error errText number errNum

    -- User cancelled error
    if (errNum is equal to -128) then
        set the userJustification to "CANCEL"
        display dialog "Request cancelled" buttons {"OK"}
        return userJustification

        -- Unhandled error
    else
        display dialog "Error processing the request" buttons {"OK"}
    end if

    end try
    ')

    # Exit the script if the user presses 'cancel'
    if [[ ${justification} = "CANCEL" ]]; then
        exit 1;
    fi

    #############################################
    #          Justification validations        #
    #############################################

    # Convert the justification string into an int, to check the length
    justificationLength=${#justification}

    # Justification must be over 10 characters
    if [[ ${justificationLength} -lt 10 ]]; then
        /usr/bin/osascript -e 'display alert "Please supply full justification for local admin rights" as critical'
        continue
    fi
    # Justification must be less than 240 characters (twitter style)
    if [[ ${justificationLength} -gt 240 ]] ; then
        /usr/bin/osascript -e 'display alert "Please supply justification in under 240 characters" as critical'
        continue
    fi

    break
done

#############################################
#           JSON for slack webhook          #
#############################################

# First lets echo the justification for the Jamf policy log

echo "JUSTIFICATION: ${justification}"

# e.g MLT-032
machineName=$( /usr/local/bin/jamf getComputerName | /usr/bin/xmllint --xpath "//computer_name/text()" - )

# Current time in UTC
timestamp="$( TZ=UTC date '+%d/%m/%Y %H:%M:%S' )"

# JSON formatted for Slack
# See here https://api.slack.com/messaging/composing/layouts

json=$(cat <<-END
{
  "blocks": [
    {
      "type": "divider"
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "New admin request from *${currentUser}* for ${elevationHours} hours, ${elevationMinutes} minutes" 
      }
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*Machine:* <https://mycompany.jamfcloud.com/computers.html|${machineName}>\n\n*Time:* ${timestamp}\n\n*Justification:* ${justification}"
      }
    },
    {
      "type": "divider"
    }
  ]
}
END
)

# Send the request as json to specified slack channel
response=$(/usr/bin/curl -s -o /dev/null -w  "%{http_code}" -X POST -H 'Content-Type: application/json' --data "${json}" "${slackWebhookUrl}")

# If the response is not successful - abort the request
if [[ "${response}" != "200" ]] ; then
    /usr/bin/osascript -e 'display alert "Error connecting to Slack, please try again later" as critical'
    exit 1;
fi

###########################################################################
# write a script for the launchdaemon to run to demote the user back and  #
# then pull logs of what the user did.                                    #
###########################################################################

# This script will take the following actions
# 1. Get the relevant username from the first argument supplied to the script
# 2. Look for the file and read the timestamp for when to remove access
# 3. Check whether the timestamp has alreadt passed
# 4. Generate the logs for the activity over the relevant time period
# 5. Remove admin access and clean up files
# 6. Collect the logs, and send signal to Jamf that admin was removed


cat << EOF > /Library/Application\ Support/JAMF/removeAdminRightsv2.sh
adminUser="\${1}"
echo "Admin User is \${adminUser}"
if [[ -f ${timeStampPath}/\${adminUser} ]]; then
  TZ=UTC start_time=\$( /bin/date -r \$( /bin/cat ${timeStampPath}/\${adminUser} | /usr/bin/cut -d'|' -f1 ) +"%Y-%m-%d %H:%M:%S" )
  end_time=\$( /bin/cat ${timeStampPath}/\${adminUser} | /usr/bin/cut -d'|' -f2 )
else
  TZ=UTC start_time=\$( /bin/date -v -${elevationHours}H -v -${elevationMinutes}M +"%Y-%m-%d %H:%M:%S" )
  end_time=0
fi

TZ=UTC current_timestamp=\$( /bin/date +%s )
echo "End time: \${end_time}"
echo "Current time: \${current_timestamp}"
if [[ \${current_timestamp} -ge \${end_time} ]]; then
  
  predicates=\$( /bin/cat <<END
  process beginswith "su" and eventMessage contains "tty" || \
  process=="sudo" || \
  process=="logind" || \
  process=="tccd" || \
  process=="sshd" || \
  process=="kextd" && sender == "IOKit" || \
  process=="screensharingd" || \
  process=="ScreensharingAgent" || \
  process=="loginwindow" && sender=="Security" || \
  process=="securityd" && eventMessage CONTAINS "Session" && subsystem =="com.apple.securityd"
END
  )
  /usr/bin/log show --start "\${start_time}" --timezone UTC --predicate "\${predicates}" >> "/private/var/userToRemove/\${adminUser}.log"

  echo "Removing \${adminUser}'s admin privileges..."
  /bin/ps -A | /usr/bin/grep 'sudo su' | /usr/bin/awk '{print \$1}' | /usr/bin/xargs kill -9
  /usr/sbin/dseditgroup -o edit -d \${adminUser} -t user admin
  /bin/rm -f ${timeStampPath}/\${adminUser}
  /bin/rm ${launchDaemonPath}
  /bin/launchctl bootout system/${launchDaemonLabel}

  echo "User demoted.  Running log collection..."
  /usr/local/bin/jamf policy -event logcollection -forceNoRecon
  /usr/local/bin/jamf recon
  /bin/rm -f "/private/var/userToRemove/\${adminUser}.log"
  /usr/bin/osascript -e 'display dialog "Your admin privileges have been removed" with icon stop buttons {"OK"}'
fi
EOF

#########################################################
# write a daemon that will let you remove the privilege #
# with another script and chmod/chown to make 			#
# sure it'll run, then load the daemon					#
#########################################################

# Check if the LaunchDaemon plist already exists, and if so, bootout and remove it
if [[ -f ${launchDaemonPath} ]]; then
  echo "Existing LaunchDaemon found.  Deleting..."
  /bin/launchctl bootout system/${launchDaemonLabel}
  /bin/rm -f "$launchDaemonPath"
fi

# Create the LaunchDaemon plist using PlistBuddy
/usr/libexec/PlistBuddy \
  -c "Add :Label string ${launchDaemonLabel}" \
  -c "Add :ProgramArguments array" \
  -c "Add :ProgramArguments:0 string /bin/zsh" \
  -c "Add :ProgramArguments:1 string /Library/Application Support/JAMF/removeAdminRightsv2.sh" \
  -c "Add :ProgramArguments:2 string ${currentUser}" \
  -c "Add :StandardOutPath string ${timeStampPath}/output.log" \
  -c "Add :StandardErrorPath string ${timeStampPath}/output.log" \
  -c "Add :RunAtLoad bool true" \
  -c "Add :StartInterval integer 300" \
  "${launchDaemonPath}"

# /bin/sleep 10

if [[ ! -f "${launchDaemonPath}" ]]; then
  echo "Error creating LaunchDaemon: ${launchDaemonPath}"
  exit 1
fi

# Set ownership and permissions
/usr/sbin/chown root:wheel "${launchDaemonPath}" || ( echo "Error changing LaunchDaemon ownership: ${launchDaemonPath}"; exit 1 )
bin/chmod 644 "${launchDaemonPath}" || ( echo "Error changing LaunchDaemon ownership: ${launchDaemonPath}"; exit 1 )

#########################
# make file for removal #
#########################

if [[ ! -d ${timeStampPath} ]]; then
  /bin/mkdir -p ${timeStampPath}
fi

current_timestamp=$( /bin/date +%s )
removal_timestamp=$( /bin/date -v +${elevationHours}H -v +${elevationMinutes}M +%s )
echo "${current_timestamp}|${removal_timestamp}" > "${timeStampPath}/${currentUser}"

##################################################################
#  Give the user admin privileges - exit if there was a problem  #
###################################################################

echo "JUSTIFICATION: $justification" > /private/var/userToRemove/$currentUser.log
/usr/sbin/dseditgroup -o edit -a $currentUser -t user admin || { /usr/bin/osascript -e 'display dialog "Error raising profile to admin - please contact IT" buttons {"OK"}' && exit 1; }

###########################
#  Load the LaunchDaemon  #
###########################

/bin/launchctl bootstrap system "${launchDaemonPath}"
# /bin/sleep 10

/usr/bin/osascript -e 'display dialog "Your profile has been elevated to Admin for '"${elevationHours}"' hours and '"${elevationMinutes}"' minutes" buttons {"OK"}'