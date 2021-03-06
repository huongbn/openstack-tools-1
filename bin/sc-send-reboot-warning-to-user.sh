#!/bin/bash
# sc-send-reboot-warning-to-user.sh
#
# finds out who has started an instance (or all instances allocated on an hypervisor), as well as the tech contact for the
# VM's project and sends them an email via sendmail (or $MAIL_CMD) on behalf of the Name/email specified in the command line.
#
# Requires: shell with admin OS credentials loaded and nova / openstack python clients installed.
# Currently requires also a configured mail client supporting recipient as argument and mail headers on mail text.
# It uses sendmail by default, but you can override it passing your mail command as the $MAIL_CMD environment variable. 
# Also the mail message can be overridden passing $MESSAGE environment variable, that must contain headers+text mail message.
#
# - 2do: choose sending mail client
# - 2do: should warn about VMs started from a member of s3it and not belonging to our projects
# - 2do: choose mail text
# - 2do: aggregate VM ids and names so that only 1 mail is sent even for multiple vms (.. maybe) 
#

set -e

USAGE="$0 HYPERVISOR|VM_ID REASON SENDER_EMAIL SENDER_NAME [--dry-run]"
    
# check if a openstack username is set...
[ -z "$OS_USERNAME" ] && {
    echo "Error: No openstack username set."
    echo "Did you load your OpenStack credentials??"
    exit 42
}

[ 4 -ne $# ] && {
    if [ 5 -eq $# ]; then
        [ "--dry-run" = "$5" ] || { 
            echo "Syntax Error: Wrong argument number 5" >&2
            echo $USAGE
            exit 1
        }
        DRY_RUN=true;
    else
        echo "Syntax Error: Wrong arguments" >&2
        echo $USAGE
        exit 1
    fi
}

ARG1=$(echo $1 | tr '[:upper:]' '[:lower:]')
echo $ARG1
#check if arg 1 is an hypervisor or an UUID
if [[ $ARG1 =~ ^node-[a-z][0-9][0-9]?-[0-9][0-9](-[0-9][0-9])?$ ]]; then
    HYPERVISOR=$ARG1
elif [[ $ARG1 =~ ^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$ ]]; then
    VM_ID=$ARG1
else
    echo "Error: Invalid argument: '$1'" >&2
    echo $USAGE
    exit 2
fi

#check if arg 2 is a valid REASON
#maybe not
REASON="an unknown reason"
[ -z "$2" ] || REASON="$2"

#sender argument is here in case you need to override the sender field of the message.
#check if arg 3 is a valid sender..
[[ "$3" =~ ^[a-z0-9.]+@.*uzh\.ch$ ]] || {
    echo "Error: Invalid sender email: '$3'" >&2
    echo $USAGE
    exit 3
}
SENDER_EMAIL="$3"

[[ "$4" =~ ^[A-Z][a-z]+\ [A-Z][a-z]+$ ]] || {
    echo "Error: Invalid sender name: '$4'" >&2
    echo $USAGE
    exit 4
}

SENDER_NAME="$4"

#sendmail or mail or mutt or ??!!
# I'd use sendmail...
# You could override this passing your mail command as an environment variable. Must support recipient as argument.
[ -z "$MAIL_CMD" ] && MAIL_CMD="sendmail"

echo -n "Using "
[ -z $HYPERVISOR ] || echo Hypervisor hostname 
[ -z $VM_ID ] || echo VM UUID


if [ ! -z $HYPERVISOR ]; then
    vm_id_list="$(nova hypervisor-servers $HYPERVISOR | egrep -o '[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}')"
else
    vm_id_list="$VM_ID"
fi

[ -z "$vm_id_list" ] && { echo "ERROR: empty vm_id_list!"; exit 5; }


for vm_id in $vm_id_list; do
    os_server_show_out=$(openstack server show $vm_id)
    echo "$os_server_show_out"
    os_user_id=$(echo "$os_server_show_out" | grep user_id | tr -d '|' | sed 's/user_id //g')
    os_project_id=$(echo "$os_server_show_out" | grep project_id | tr -d '|' | sed 's/project_id //g')
    vm_instance_name=$(echo "$os_server_show_out" | grep -A 1 key_name | tail -n1 | tr -d '|' | sed 's/name //' | tr -d '[:blank:]')
    os_user_email=$(openstack user show $os_user_id | grep email | tr -d '|' | tr -d '[:blank:]' | sed 's/^email//')
    os_project_contact=$(openstack project show $os_project_id | grep contact_email | tr -d '|' | tr -d '[:blank:]' | sed 's/^contact_email//') 
    #echo $vm_id
    #echo $vm_instance_name
    #echo $os_user_email
    #echo $os_project_id
    #echo $os_project_contact
    if [ -z "$vm_instance_name" ] || [ -z "$os_user_email" ]; then   
        echo "WARNING: Could not retrieve instance name or user email for '$vm_id' in project '$os_project_id'!"
        echo "\tSkipping: you will need to do it manually..."
        continue
    fi

    echo "Sending mail about '$vm_id' to '$os_user_email' and '$os_project_contact' in 'CC'"
    message=$(cat <<Endofmessage
From: "$SENDER_NAME" <$SENDER_EMAIL>
Reply-To: help@s3it.uzh.ch
To: $os_user_email
CC: $os_project_contact
Subject: ScienceCloud instance "$vm_instance_name" was rebooted

Dear ScienceCloud user,
this is a notification that your instance "$vm_instance_name" with UUID "$vm_id" has been rebooted due to $REASON.

Please check that all the services are working as expected, and that any attached volumes are mounted correctly.

Apologies for any inconvenience this may have caused you.

If you have questions or need further support please write to help@s3it.uzh.ch

Best regards,

--
On behalf of S3IT,
$SENDER_NAME
Services and Support for Science IT (S3IT)
University of Zurich
Endofmessage
    )
    echo
    echo "$message"
    echo
    echo "Sending it with \"$MAIL_CMD $os_user_email\""

    if [ "$DRY_RUN" = "true" ]; then
        echo
        echo "-----> THIS IS A DRY RUN - NO MAIL WAS SENT!!!!"
        echo
    else
        #send message
        echo "$message" | $MAIL_CMD $os_user_email
        echo
        echo "-----> The message was sent! (retcode $?)"
        echo
    fi

done

