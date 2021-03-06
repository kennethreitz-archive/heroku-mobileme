#!/bin/bash
# Script for downloading the contents of a .me.com domain for one user.
#
# Usage:   dld-me-com.sh ${DOMAIN} ${USERNAME}
# where DOMAIN is one of  gallery.me.com
#                         web.me.com
#                         public.me.com
#                         homepage.mac.com
#

VERSION="20111107.01"

# this script needs wget-warc, which you can find on the ArchiveTeam wiki.
# set the WGET_WARC environment variable to point to the wget-warc executable.

if [[ ! -x $WGET_WARC ]]
then
  WGET_WARC=$(which wget)
  if ! $WGET_WARC --help | grep -q WARC
  then
    echo "${WGET_WARC} does not support WARC. Set the WGET_WARC environment variable."
    exit 3
  fi
fi

if [[ ! -x $WGET_WARC ]]
then
  echo "wget-warc not found. Set the WGET_WARC environment variable."
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

USER_AGENT="Mozilla/5.0 (Windows; U; Windows NT 6.1; en-US) AppleWebKit/533.20.25 (KHTML, like Gecko) Version/5.0.4 Safari/533.20.27"

domain="$1"
username="$2"
userdir="data/${username:0:1}/${username:0:2}/${username:0:3}/${username}/${domain}"

if [[ -f "${userdir}/.incomplete" ]]
then
  echo "  Deleting incomplete result for ${domain}/${username}"
  rm -rf "${userdir}"
fi

if [[ -d "${userdir}" ]]
then
  echo "  Already downloaded ${domain}/${username}"
  exit 2
fi

mkdir -p "${userdir}"
touch "${userdir}/.incomplete"

echo "  Downloading ${domain}/${username}"


# step 1: download the list of files

if [[ "$domain" =~ "public.me.com" ]]
then

  # public.me.com has real WebDAV

  # PROPFIND with Depth: infinity lists all files
  echo -n "   - Discovering urls (XML)..."
  curl "https://public.me.com/ix/${username}/" \
       --silent \
       --request PROPFIND \
       --header "Content-Type: text/xml; charset=\"utf-8\"" \
       --header "Depth: infinity" \
       --data '<?xml version="1.0" encoding="utf-8"?><DAV:propfind xmlns:DAV="DAV:"><DAV:allprop/></DAV:propfind>' \
       --user-agent "${USER_AGENT}" \
     > "$userdir/webdav-feed.xml"
  result=$?
  if [ $result -ne 0 ]
  then
    echo " ERROR ($result)."
    exit 1
  fi
  echo " done."

  # grep for href, strip <D:href> and prepend https://public.me.com
  grep -o -E "<D:href>[^<]+" "$userdir/webdav-feed.xml" | cut -c 9- | awk '/[^\/]$/ { print "https://public.me.com" $1 }' | sort | uniq > "$userdir/urls.txt"
  count=$( cat "$userdir/urls.txt" | wc -l )

elif [[ ! "$domain" =~ "homepage.mac.com" ]]
then

  # web.me.com and gallery.me.com use query-string WebDAV

  # there's a json feed...
  echo -n "   - Discovering urls (JSON)..."
  curl "http://${domain}/${username}/?webdav-method=truthget&feedfmt=json&depth=Infinity" \
       --silent \
       --user-agent "${USER_AGENT}" \
     > "$userdir/webdav-feed.json"
  result=$?
  if [ $result -ne 0 ]
  then
    echo " ERROR ($result)."
    exit 1
  fi
  echo " done."

  # ... and an xml feed
  echo -n "   - Discovering urls (XML)..."
  curl "http://${domain}/${username}/?webdav-method=truthget&depth=Infinity" \
       --silent \
       --user-agent "${USER_AGENT}" \
     > "$userdir/webdav-feed.xml"
  result=$?
  if [ $result -ne 0 ]
  then
    echo " ERROR ($result)."
    exit 1
  fi
  echo " done."

  # for web.me.com we look at the xml feed, which contains the files,
  # for gallery.me.com we use the json feed, which lists the images
  if [[ "$domain" =~ "web.me.com" ]]
  then
    grep "href=\"" "$userdir/webdav-feed.xml" | grep -oE "http://${domain}/[^\"<]+" | sort | uniq > "$userdir/urls.txt"
  elif [[ "$domain" =~ "gallery.me.com" ]]
  then
    # we do not want the ?derivative=...
    grep -oE "http://${domain}/[^\"<]+" "$userdir/webdav-feed.json" \
      | grep -E "\.([a-zA-Z0-9]+)$" \
      | sort | uniq \
      > "$userdir/urls.txt"
  else
    echo "  Invalid domain ${domain}."
    exit 1
  fi

  # let's save the feeds in the warc file
  echo "http://${domain}/${username}/?webdav-method=truthget&feedfmt=json&depth=Infinity" >> "$userdir/urls.txt"
  echo "http://${domain}/${username}/?webdav-method=truthget&depth=Infinity" >> "$userdir/urls.txt"

  count=$( cat "$userdir/urls.txt" | wc -l )

fi

# some web.me.com sites use iWeb, which doesn't always show up in the feed-XML

if [[ "$domain" =~ "web.me.com" ]]
then

  # first, we crawl the site
  echo -n "   - Discovering iWeb (directories)..."
  $WGET_WARC -U "$USER_AGENT" -nv -o "$userdir/wget-discovery.log" \
      --directory-prefix="$userdir/files/" \
      -r -l inf --no-remove-listing \
      --trust-server-names \
      "http://${domain}/$username/" \
      --no-check-certificate
  result=$?
  if [ $result -ne 0 ] && [ $result -ne 6 ] && [ $result -ne 8 ]
  then
    echo " ERROR ($result)."
    exit 1
  fi
  rm -rf "$userdir/files/"
  echo " done."

  # we should download the files we've discovered
  cut -d " " -f 3 "$userdir/wget-discovery.log" \
    | grep URL: | cut -c 5- >> "$userdir/urls.txt"

  echo -n "   - Discovering iWeb (feed.xml)..."
  # then we look at the directories we've discovered
  directories=$( grep -oE "http://web.me.com.+/" "$userdir/urls.txt" | sort | uniq )
  for d in $directories
  do
    # download the feed.xml for this directory
    feedxml_url="${d}feed.xml"

    extra_files=$( curl "${feedxml_url}" --silent --user-agent "${USER_AGENT}" \
                     | grep -oE 'href="[^"]+' | cut -c 7- )
    for f in $extra_files
    do
      if [[ ! $f =~ http ]]
      then
        f="${d}${f}"
      fi
      echo $f >> "$userdir/urls.txt"
    done

    # add it to the final download
    echo "$feedxml_url" >> "$userdir/urls.txt"
  done
  echo " done."

  # some sites have a Sites.rss with urls
  echo -n "   - Looking for Sites.rss..."
  # get Sites.rss, extract urls
  curl "http://${domain}/${username}/Sites.rss" --silent --user-agent "${USER_AGENT}" \
    | grep -oE '<link>[^<]+' | cut -c 7- | sed "s/web.mac.com/web.me.com/" >> "$userdir/urls.txt"

  # add Sites.rss to WARC
  echo "http://${domain}/${username}/Sites.rss" >> "$userdir/urls.txt"
  echo " done."

  # sometimes Sites.rss or the feeds include links to external domains,
  # the user's web site. these domains don't always exist.
  #
  # to prevent wget from returning a dns error and since the content
  # on web.me.com is the same as that on the external domain we
  # only include the urls from web.me.com
  echo -n "   - Sorting url list..."
  cat "$userdir/urls.txt" \
    | grep -E "^http://web.me.com/" \
    | sort | uniq > "$userdir/unique-urls.txt"
  mv "$userdir/unique-urls.txt" "$userdir/urls.txt"
  echo " done."

  count=$( cat "$userdir/urls.txt" | wc -l )

fi


# step 2: use the url list to download the files

if [[ "$domain" =~ "homepage.mac.com" ]]
then

  # homepage.mac.com doesn't have a feed with file names, so we'll use wget --mirror

  echo -n "   - Running wget --mirror (takes a while)..."
  $WGET_WARC -U "$USER_AGENT" -nv -o "$userdir/wget.log" \
      --directory-prefix="$userdir/files/" \
      -r -l inf --no-remove-listing \
      --trust-server-names \
      --page-requisites "http://${domain}/$username/" \
      --exclude-directories="/WebObjects/FileSharing.woa/" \
      --no-check-certificate \
      --warc-file="$userdir/${domain}-$username" --warc-max-size=inf \
      --warc-header="operator: Archive Team" \
      --warc-header="mobileme-dld-script-version: ${VERSION}" \
      --warc-header="mobileme: ${domain}, ${username}"
  result=$?
  if [ $result -ne 0 ] && [ $result -ne 6 ] && [ $result -ne 8 ]
  then
    echo " ERROR ($result)."
    exit 1
  fi
  rm -rf "$userdir/files/"
  echo " done."

elif [[ "$domain" =~ "web.me.com" ]]
then

  # for web.me.com we should use --mirror and --page-requisites

  # for some reason wget does not always create the directories,
  # so we'll do it in advance
  echo -n "   - Preparing directory structure..."
  cat "$userdir/urls.txt" | while read url
  do
    url=${url/#http:\/\//}
    url=${url/#https:\/\//}
    url=$( echo "$url" | sed 's/+/ /g; s/%/\\x/g' )
    url=$( echo -e "$url" )
    url_path="$userdir/files/"$( dirname "$url" )
    [ ! -d "$url_path" ] && mkdir -p "$url_path"
  done
  echo " done."

  echo -n "   - Running wget --mirror (at least ${count} files)..."
  $WGET_WARC -U "$USER_AGENT" -nv -o "$userdir/wget.log" \
      -i "$userdir/urls.txt" \
      --directory-prefix="$userdir/files/" \
      -r -l inf --no-remove-listing \
      --trust-server-names \
      --page-requisites \
      --span-hosts --domains="web.me.com,www.me.com" \
      --exclude-directories="/g/" \
      --no-check-certificate \
      --warc-file="$userdir/${domain}-$username" --warc-max-size=inf \
      --warc-header="operator: Archive Team" \
      --warc-header="mobileme-dld-script-version: ${VERSION}" \
      --warc-header="mobileme: ${domain}, ${username}"
  result=$?
  if [ $result -ne 0 ] && [ $result -ne 6 ] && [ $result -ne 8 ]
  then
    echo " ERROR ($result)."
    exit 1
  fi
  rm -rf "$userdir/files/"
  echo " done."

else

  # for the other domains we just grab every url on the list

  echo -n "   - Downloading (${count} files)..."
  $WGET_WARC -U "$USER_AGENT" -nv -o "$userdir/wget.log" -i "$userdir/urls.txt" -O /dev/null \
      --no-check-certificate \
      --warc-file="$userdir/${domain}-$username" --warc-max-size=inf \
      --warc-header="operator: Archive Team" \
      --warc-header="mobileme-dld-script-version: ${VERSION}" \
      --warc-header="mobileme: ${domain}, ${username}"
  result=$?
  if [ $result -ne 0 ] && [ $result -ne 6 ] && [ $result -ne 8 ]
  then
    echo " ERROR ($result)."
    exit 1
  fi
  echo " done."

fi

echo -n "   - Result: "
if du --help | grep -q apparent-size
then
  du --apparent-size -hs "$userdir/${domain}-$username"* | cut -f 1
else
  du -hs "$userdir/${domain}-$username"* | cut -f 1
fi

rm "${userdir}/.incomplete"

exit 0

