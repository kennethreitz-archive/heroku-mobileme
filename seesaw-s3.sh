#!/bin/bash
#
# Distributed downloading script for me.com/mac.com.
#
# This script will download a user's data to this computer.
# It will continue downloading users until there is 10GB of
# data, then generates a tar file and pushes it to IA-S3.
# The script will then quit and wait for Heroku to restart it.
#
# Usage:
#   ./seesaw-s3.sh $YOURNICK $ACCESSKEY $SECRET
#
# ACCESSKEY and SECRET are your IA S3 keys:
#   http://www.archive.org/account/s3.php
#

# this script needs wget-warc, which you can find on the ArchiveTeam wiki.
# copy the wget executable to this script's working directory and rename
# it to wget-warc

if [ ! -x ./wget-warc ]
then
  echo "wget-warc not found. Download and compile wget-warc and save the"
  echo "executable as ./wget-warc"
  exit 3
fi

# the script also needs curl with SSL support

if ! builtin type -p curl &>/dev/null
then
  echo "You don't have curl."
  exit 3
fi

if ! curl -V | grep -q SSL
then
  echo "Your version of curl doesn't have SSL support."
  exit 3
fi

youralias="$1"
accesskey="$2"
secret="$3"

if [[ ! $youralias =~ ^[-A-Za-z0-9_]+$ ]]
then
  echo "Usage:  $0 {nickname}"
  echo "Run with a nickname with only A-Z, a-z, 0-9, - and _"
  exit 4
fi

mkdir -p data/

VERSION=$( grep 'VERSION=' dld-me-com.sh | grep -oE "[-0-9.]+" )

max_bytes=$(( 5 * 1024 * 1024 * 1024 ))

bytes=0
while [[ $bytes -le $max_bytes ]]
do
  # request a username
  echo -n "Getting next username from tracker..."
  tracker_no=$(( RANDOM % 3 ))
  tracker_host="memac-${tracker_no}.heroku.com"
  username=$( curl -s -f -d "{\"downloader\":\"${youralias}\"}" http://${tracker_host}/request )

  # empty?
  if [ -z $username ]
  then
    echo
    echo "No username. Sleeping for 30 seconds..."
    echo
    sleep 30
  else
    echo " done."

    if ! ./dld-user.sh "$username"
    then
      echo "Error downloading '$username'."
      exit 6
    fi

    echo "$username" >> to-upload.txt

    bytes=$( du -bs data/ | cut -f 1 )
    bytes_perc=$(( (100 * bytes) / max_bytes ))
    echo "---> ${bytes_perc}% full."
  fi
done

echo "Making a tar file..."
if ! tar cf to-upload.tar -C data/ .
then
  echo "Tar problem!"
  exit 6
fi

number=$( curl -s -f "http://${tracker_host}/s3-bin" )

# create items of 20 files, but do not do concurrent uploads
# to one item at the same time
stripes=8
per_set=40
set_number=$(( 1 + (number / (stripes * per_set)) * stripes + (number % stripes) ))

#             --header 'x-archive-meta-collection:archiveteam-mobileme' \

echo "Uploading..."
while ! curl -v --fail --retry 100 --location \
             --header 'x-amz-auto-make-bucket:1' \
             --header 'x-archive-queue-derive:0' \
             --header 'x-archive-meta-mediatype:web' \
             --header "x-archive-meta-title:ArchiveTeam MobileMe Panic Download: Set hero-${set_number}" \
             --header 'x-archive-meta-date:'$( date +"%Y-%m" ) \
             --header 'x-archive-meta-year:'$( date +"%Y" ) \
             --header "authorization: LOW ${accesskey}:${secret}" \
             --upload-file to-upload.tar \
             "http://s3.us.archive.org/archiveteam-mobileme-hero-${set_number}/archiveteam-mobileme-hero-${set_number}-${number}.tar"
do
  echo "Upload error. Wait and try again."
  sleep 60
done

echo -n "Upload complete. Uploading user list... "
while ! curl -v --fail --retry 100 --location \
             --header 'x-amz-auto-make-bucket:1' \
             --header 'x-archive-queue-derive:0' \
             --header 'x-archive-meta-mediatype:web' \
             --header "x-archive-meta-title:ArchiveTeam MobileMe Panic Download: Set hero-${set_number}" \
             --header 'x-archive-meta-date:'$( date +"%Y-%m" ) \
             --header 'x-archive-meta-year:'$( date +"%Y" ) \
             --header "authorization: LOW ${accesskey}:${secret}" \
             --upload-file to-upload.txt \
             "http://s3.us.archive.org/archiveteam-mobileme-hero-${set_number}/archiveteam-mobileme-hero-${set_number}-${number}.txt"
do
  echo "Upload error. Wait and try again."
  sleep 60
done

echo "done."
echo
echo

for username in $( cat to-upload.txt )
do
  # statistics!
  i=0
  bytes_str="{"
  domains="web.me.com public.me.com gallery.me.com homepage.mac.com"
  for domain in $domains
  do
    userdir="data/${username:0:1}/${username:0:2}/${username:0:3}/${username}/${domain}"
    if [ -d $userdir ]
    then
      if du --help | grep -q apparent-size
      then
        bytes=$( du --apparent-size -bs $userdir | cut -f 1 )
      else
        bytes=$( du -bs $userdir | cut -f 1 )
      fi
      if [[ $i -ne 0 ]]
      then
        bytes_str="${bytes_str},"
      fi
      bytes_str="${bytes_str}\"${domain}\":${bytes}"
      i=$(( i + 1 ))
    fi
  done
  bytes_str="${bytes_str}}"

  # some more statistics
  ids=($( grep -h -oE "<id>urn:apple:iserv:[^<]+" \
            "data/${username:0:1}/${username:0:2}/${username:0:3}/${username}/"*"/webdav-feed.xml" \
            | cut -c 21- | sort | uniq ))
  id=0
  if [[ ${#ids[*]} -gt 0 ]]
  then
    id="${#ids[*]}:${ids[0]}:${ids[${#ids[*]}-1]}"
  fi

  success_str="{\"downloader\":\"${youralias}\",\"user\":\"${username}\",\"bytes\":${bytes_str},\"version\":\"${VERSION}\",\"id\":\"${id}\"}"
  echo "${success_str}" >> success-strs.txt

  delay=1
  while [ $delay -gt 0 ]
  do
    echo "Telling tracker that '${username}' is done."
    tracker_no=$(( RANDOM % 3 ))
    tracker_host="memac-${tracker_no}.heroku.com"
    resp=$( curl -s -f -d "$success_str" http://${tracker_host}/done )
    if [[ "$resp" != "OK" ]]
    then
      echo "ERROR contacting tracker. Could not mark '$username' done."
      echo "Sleep and retry."
      sleep $delay
      delay=$(( delay * 2 ))
    else
      delay=0
    fi
  done
  echo
done

rm -rf data/*
rm to-upload.tar
rm to-upload.txt
