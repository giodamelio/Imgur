#!/bin/bash
# Requirements: bash, basename, mktemp, curl, (g)awk, sed

# htmltemp holds .html file for quick, multiple searches
# logfile holds failed cURL downloads

# Declarations
htmlname="$(basename $0)"
logname="$htmlname"
htmltemp="$(mktemp -t ${htmlname}.XXXXX).html" || exit 1
rawtemp="$(mktemp -t ${htmlname}.XXXXX).raw"   || exit 1
logfile="$(mktemp -t ${logname}.XXXXX).log"    || exit 1

time_start="$(date +%s)"
folderexists="TRUE"
multiple_urls="FALSE"
sanitize="FALSE"
preserve="FALSE"
silent_flag="FALSE"
debug_flag="FALSE"
curl_args="-s"
data_index=-1
count=0
gallery_url=('')

# Functions
function long_desc()
{
  cat << EOF
NAME
    imgur - a simple album downloader

SYNOPSIS
    Download albums from imgur.com while retaining order.

OPTIONS
    -h        Show this message.
    -c        Clean nonalphanumeric characters from the album's name.
    -p        Preserve imgur's naming. (Warning! This will not retain order.)
    -s        Silent mode. Overrides debug mode.
    -d        Debug mode.

EXAMPLES
    bash imgur.bash http://imgur.com/a/fG58m#0
    bash imgur.bash reactiongifsarchive.imgur.com

ERROR CODES
    1: General failure.
    6: Could not resolve host (cURL failure).
  127: Command not found.

AUTHOR
    manabutameni
    https://github.com/manabutameni/Imgur

EOF
exit 0
}

function short_desc()
{
  stdout "usage: $0 [-cps] URL [URL]"
  exit 1
}

function systems_check()
{
  failed="FALSE"
  command -v bash   > /dev/null || { failed="TRUE"; echo Bash   not installed.; }
  command -v mktemp > /dev/null || { failed="TRUE"; echo mktemp not installed.; }
  command -v curl   > /dev/null || { failed="TRUE"; echo cURL   not installed.; }
  command -v awk    > /dev/null || { failed="TRUE"; echo awk    not installed.; }
  command -v sed    > /dev/null || { failed="TRUE"; echo sed    not installed.; }
  if [[ "$failed" == "TRUE" ]]
  then
    exit 127
  fi
  debug 'All system requirements met.'
}

function stdout()
{
  # Normal output is suppressed when debug flag is raised.
  if [[ "$debug_flag" == "FALSE" ]] && [[ "$silent_flag" == "FALSE" ]]
  then
    echo "$@"
  fi
}

function debug()
{
  # Debug output is suppressed when silent flag is raised.
  if [[ "$debug_flag" == "TRUE" ]] && [[ "$silent_flag" == "FALSE" ]]
  then
    echo "[$(echo "$(date +%s) - $time_start" | bc)] DEBUG: $@" 1>&2
  fi
}

function parse_folder_name()
{
  # ;exit is needed since sometimes data-title appears twice
  temp_folder_name="$(awk -F\" '/data-title/ {print $6; exit}' $htmltemp)"
  temp_folder_name=$(sed "s/&#039;/'/g" <<< "$temp_folder_name")

  if [[ "$sanitize" == "TRUE" ]]
  then # remove special characters
    clean="${temp_folder_name//_/}"              # turn / into _
    clean="${clean// /_}"                        # turn spaces into _
    temp_folder_name="${clean//[^a-zA-Z0-9_]/}" # remove all special chars
  else
    temp_folder_name="$(sed 's/\//_/g' <<< $temp_folder_name)" # ensure no /
  fi

  if [[ "$preserve" == "TRUE" ]] || [ -z "$temp_folder_name" ]
  then # Create a name for a folder name based on the URL.
    temp_folder_name="$(basename "$url" | sed 's/\#.*//g')"
  fi
  
  echo "$temp_folder_name"
}

function evaluate()
{
  # Evaluate a floating point number expression.
  # There must be an argument and it must be an integer.
  # Example: evaluate 3 "4 * 5.2" ; # would set the scale to 3
  scale="$1"
  shift 1
  echo "$(echo "scale=$scale; $@" | bc -q 2> /dev/null)"
}

function progress_bar()
{
  if [[ "$debug_flag" == "FALSE" ]]
  then
    printf "[%60s]       \r" " " # clear each time in case of accidental input.
    printf "[%60s] $1\045\r" " " # Print off the percent completed passed to $1
    printf "[%${2}s>\r" " " | tr ' ' '=' # Print progress bar as '=>'
    if [[ "$2" == "60.00" ]]
    then # Display completed progress bar.
      printf "[%${2}s]\r" " " | tr ' ' '='
    fi
  fi
}

# Option Parsing
while getopts ":hdcps" OPTION
do
  case $OPTION in
    h)
      long_desc
      ;;
    d)
      # print debugging messages
      debug_flag="TRUE" && debug "Debug Flag Raised"
      ;;
    c)
      # Clean non alpha-numeric characters from album name.
      sanitize="TRUE" && debug "Clean Flag Raised" 
      ;;
    p)
      # Preserve Imgur's naming scheme. Please note that this will not keep the
      # order of the images. While this does break the spirit of the script it
      # is included here for the sake of completion.
      preserve="TRUE" && debug "Preserve Flag Raised" 
      ;;
    s)
      # Run silently.
      curl_args="-s"
      silent_flag="TRUE" && debug "Silent Flag Raised" 
      ;;
    '?' | *)
      stdout "Invalid option: -$OPTARG" >&2
      short_desc
      ;;
  esac
done
shift $((OPTIND - 1))

systems_check
gallery_url=("$@")

if [[ "$debug_flag" == "TRUE" ]]
then
  for (( i = 0 ; i < "${#@}" ; i++ ))
  do
    debug "gallery_url[$i] = ${gallery_url[$i]}" 
  done
fi

# make sure gallery_url isn't empty.
if [[ -z "${gallery_url[0]}" ]]
then
  debug '$gallery_url[0] is empty'
  short_desc
  exit 1
fi

# Program Begins
for url in "${gallery_url[@]}" 
do
  if [[ "$url" =~ 'all#' ]]
  then # remove erroneous text from end of URL for proper parsing.
    index="$(awk -v a="$url" -v b="all#" 'BEGIN{print index(a,b)}')" 
    let "index = $index - 2"
    url="${url:0:$index}"
  fi
  debug 'url = ' "$url"
  count=0 # Reset counter
  if [[ "$url" =~ "imgur.com/a/" ]]
  then
    # Download the html source to a temp file for quick parsing.
    curl -s "$url" > "$htmltemp"

    debug 'html temp = ' "$htmltemp"
    debug 'log file  = ' "$logfile"
    debug 'raw temp  = ' "$rawtemp"

    folder_name="$(parse_folder_name)"

    # It only takes one album named Pictures to possibly screw up
    # an entire folder. This will also save images to a new directory
    # if the script is used twice on the same album in the same folder.
    test -d "$folder_name" || folderexists="FALSE"

    if [[ "$folderexists" == "TRUE" ]]
    then
      tempdir="$(mktemp -d "$folder_name"_XXXXX)" || exit 1
      folder_name="$tempdir"
    else
      mkdir -p "$folder_name"
    fi

    debug 'folder name = '"$folder_name" 

    # Parse image descriptions. Note: already in order. Descriptions separated by newlines.
    grep -i "images[[:space:]]*:" "$htmltemp" > "$rawtemp"
    # Find the list of descriptions at the end of the html source, cut it out and save it, replacing html-source with equivalent ascii.
    grep '"count":' "$htmltemp" | awk '{gsub(/\,/,"\n,");print}' | sed "s,&#039;,\',g" > "$rawtemp"
    # From that file, parse a list of descriptions, and apply some custom formatting.
    sed -n '/description/,/width/p' "$rawtemp" | sed '/,"width":/d' | tr -d '\n' > "$rawtemp.0"
    # From THAT file, apple some more formatting, send file to download folder.
    awk '{gsub(/\,"description":"/,"\n\n");print}' "$rawtemp.0" |  sed -e 's/<[^>]*>//g' | sed 's/\\\//\//g' > "$folder_name"/descriptions.txt

    # Save link to album in a text file with the images.
    echo "$url" >> "$folder_name"/"permalink.txt"
    debug 'permalink: ' "$folder_name"/"permalink.txt"

    # Get total number of images to properly display percent done.
    total_images=0
    for image_url in $(awk -F\" '/data-src/ {print $10}' "$htmltemp" | sed '/^$/d')
    do
      let "total_images = $total_images + 1"
    done
    debug '$total_images = ' "$total_images"

    # Iterate over all images found.
    for image_url in $(awk -F\" '/data-src/ {print $10}' "$htmltemp" | sed '/^$/d')
    do
      # Some albums have the thumbnail images out of order in the html source,
      # this fixes that.
      data_index="$(grep $image_url $htmltemp | awk -F\" '{print $12}')"
      let "data_index = $data_index + 1"
      data_index="$(echo $data_index)" # necessary to remove preceding newline.
      debug "data_index: $data_index"

      # Ensure no images are thumbnails.
      # Always works because all images that could be in $image_url are currently
      # thumbnails.
      image_url=$(sed 's/s.jpg/.jpg/g' <<< "$image_url")
      debug "image_url dethumbnailed: $image_url"

      if [[ "$preserve" == "TRUE" ]]
      then # Preserve imgur naming conventions.
        image_name="$(basename "$image_url")"
      else # name images based on index value.
        image_name="$data_index.jpg"
      fi

      debug "Downloading image: $(($count+1))" '$count+1'
      # This is where the file is actually downloaded
      # If a download fail we are going to give a best effort and place links to
      # images that were not downloaded properly into $logfile.
      curl "$curl_args" "$image_url" > "$folder_name"/"$image_name" ||
        printf "failed to download: $image_url \n" >> "$logfile"

      if [[ "$preserve" == "TRUE" ]]
      then # rename current file to force {1..11} sorting.
        # This is needed so the next if statement can always get the right file.
        new_image_name="$image_name"
      else
        # brief expl:     force 5 digits   basename         extension
        new_image_name="$(printf %05d.%s ${image_name%.*} ${image_name##*.})"
        mv "$folder_name"/"$image_name" "$folder_name"/"$new_image_name"
        debug "Preserved Image Name: $new_image_name"
      fi

      # Read the mimetype to ensure proper image renaming.
      if [[ "$(file --brief --mime "$folder_name"/"$new_image_name" | awk -F\; '{print $1}')" == "image/gif" ]]
      then # rename the image with the proper extension.
        mv "$folder_name"/"$new_image_name" \
          "$folder_name"/"$(basename $new_image_name .jpg).gif"
      fi

      debug "Image Name: $new_image_name"

      let "count = $count + 1"
      if [[ "$silent_flag" == "FALSE" && "$count" != 0 ]]
      then # display download progress.
        percent="$(evaluate 2 "100 * $count / $total_images")"
        percent="${percent/.*}"
        prog="$(evaluate 2 "60 * $count / $total_images")"
        if [[ "$percent" =~ ^[0-9]+$ ]]
        then
          progress_bar "$percent" "$prog"
        fi
        debug "Progress: $percent%%"
      fi
    done
    stdout ""
    stdout "Finished with $count files downloaded."
  else
    stdout "Must be an album from imgur.com"
    exit 1
  fi
done

if [[ -s "$logfile" ]]
then
  stdout "Exited with errors, check $logfile"
  exit 1
else
  # Cleaning up
  debug "Completed successfully."
  exit 0
fi
