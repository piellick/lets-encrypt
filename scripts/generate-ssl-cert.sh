#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/..";

[ -f "${DIR}/opt/letsencrypt/settings"  ] && source "${DIR}/opt/letsencrypt/settings" || { echo "No settings available" ; exit 3 ; }
[ -f "${DIR}/root/validation.sh"  ] && source "${DIR}/root/validation.sh" || { echo "No validation library available" ; exit 3 ; }

#To be sure that r/w access
mkdir -p /etc/letsencrypt/
#chown -R jelastic:jelastic /etc/letsencrypt/

cd "${DIR}/opt/letsencrypt"
git reset --hard
git pull origin master

#Parameters for test certificates
test_params='';
[ "$test" == "true" -o "$1" == "fake" ] && { test_params='--test-cert --break-my-certs '; }

#Validate settings
[ "$withExtIp" == "true" ] && { validateExtIP; validateDNSSettings; }

validateCertBot

#Kill hanged certificate requests
killall -9 letsencrypt-auto > /dev/null 2>&1
killall -9 letsencrypt > /dev/null 2>&1

mkdir -p $DIR/var/log/letsencrypt

iptables -I INPUT -p tcp -m tcp --dport 12345 -j ACCEPT
ip6tables -I INPUT -p tcp -m tcp --dport 12345 -j ACCEPT
iptables -t nat -I PREROUTING -p tcp -m tcp --dport 80 -j REDIRECT --to-ports 12345
ip6tables -t nat -I PREROUTING -p tcp -m tcp --dport 80 -j REDIRECT --to-ports 12345 || ip6tables -I INPUT -p tcp -m tcp --dport 80 -j DROP
result_code=0;

#Request for certificates
resp=$($DIR/opt/letsencrypt/letsencrypt-auto certonly --standalone $test_params --domain $domain --preferred-challenges http-01 --http-01-port 12345 --renew-by-default --email $email --agree-tos --no-bootstrap --no-self-upgrade --no-eff-email --logs-dir $DIR/var/log/letsencrypt)
result_code=$?;

iptables -t nat -D PREROUTING -p tcp -m tcp --dport 80 -j REDIRECT --to-ports 12345
ip6tables -t nat -D PREROUTING -p tcp -m tcp --dport 80 -j REDIRECT --to-ports 12345 || ip6tables -I INPUT -p tcp -m tcp --dport 80 -j ACCEPT
iptables -D INPUT -p tcp -m tcp --dport 12345 -j ACCEPT
ip6tables -D INPUT -p tcp -m tcp --dport 12345 -j ACCEPT

if [ "$result_code" != "0" ]; then
    [[ $resp == *"You have an ancient version of Python"* ]] && need_regenerate=true;
fi

[[ $need_regenerate == true ]] && exit 4; #reinstall packages, regenerate certs
[[ $result_code != "0" ]] && { echo "$resp"; exit 1; } #general result error

#To be sure that r/w access
mkdir -p /tmp/
chmod -R 777 /tmp/
appdomain=$(cut -d"." -f2- <<< $appdomain)

certdir=$(sed -nr '/^[[:digit:]-]{10} [[:digit:]:]{8},[[:digit:]]+:.*:[[:alnum:]\._]*:Reporting to user: Congratulations![[:alnum:][:space:]].*$/{n;p}' $DIR/var/log/letsencrypt/letsencrypt.log | sed  's/\/[[:alpha:]]*.pem//'| tail -n 1 )

mkdir -p $DIR/var/lib/jelastic/keys/
rm -f $DIR/var/lib/jelastic/keys/*.pem

[ ! -z $certdir ] && cp -f $certdir/* $DIR/var/lib/jelastic/keys/ && chown jelastic -R $DIR/var/lib/jelastic/keys/

function uploadCerts() {
    local certdir="$1"
    echo appid = $appid
    echo appdomain = $appdomain
    #Upload 3 certificate files
    uploadresult=$(curl -F "appid=$appid" -F "fid=privkey.pem" -F "file=@${certdir}/privkey.pem" -F "fid=fullchain.pem" -F "file=@${certdir}/chain.pem" -F "fid=cert.pem" -F "file=@${certdir}/cert.pem" http://$primarydomain/xssu/rest/upload)

    #Save urls to certificate files
    echo $uploadresult | awk -F '{"file":"' '{print $2}' | awk -F ":\"" '{print $1}' | sed 's/","name"//g' > /tmp/privkey.url
    echo $uploadresult | awk -F '{"file":"' '{print $3}' | awk -F ":\"" '{print $1}' | sed 's/","name"//g' > /tmp/fullchain.url
    echo $uploadresult | awk -F '{"file":"' '{print $4}' | awk -F ":\"" '{print $1}' | sed 's/","name"//g' > /tmp/cert.url

    sed -i '/^\s*$/d' /tmp/*.url
    exit 0;
}

while [[ "$1" != "" ]]; do
    case "$1" in
        -n|--no-upload-certs )
            shift;
            exit 0;
            ;;
    esac
    shift
done

uploadCerts $certdir;
#[ "$withExtIp" == "true" ] && { uploadCerts $certdir; }
