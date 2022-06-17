#!/bin/bash

# This script is used on an admin computer to search in Jamf Pro extension attributes which of them use a specific command.
# It's using the Classic API to search.
# We recommend to have a dedicated user for that search.
# The script does the following:
#   List all scripts/extension attributes ID
#   Go through each ID, get the <script_contents_encoded> or <script> for the extension attributes
#   Decode the <script_contents_encoded> (not needed for extension attributes)
#   Search the string
#   If contains string, get <name>
#   Report with script/extension attributes ID and <name>
#   Report with URL to the script/extension attributes in Jamf Pro
#   Report lines containing the searched value

# Please change the variables according to your needs
serverURL=""        # i.e.: https://server.domain.tld:port or https://instance.jamfcloud.com
userName=""         # it is recommended to create a dedicated read-only user that has read-only access to scripts
userPasswd=""

# Check if the script is launched with sh, if yes, output some text and exit
runningShell=$(ps -hp $$ | tail -n 1 | awk '{ print $4}')
scriptName="$0"

if [[ "$runningShell" == "sh" ]]; then
    echo "You seem to be running this script using: sh $scriptName"
    echo "Please either make it executable with 'chmod u+x $scriptName' and then run './$scriptName'"
    echo "or use 'bash $scriptName'"
    echo "This script does not run well with sh"
    echo "For your convenience, we're relaunching $scriptName with bash"
    echo ""
    bash "$PWD/$scriptName" 
    exit 0
fi

##### Function CatchInvokeRestMethodErrors #####
# Function to do a curl and catch http code, if not 200, outputs a message to the user
# The function requires 4 parameters:
# -uri: url you want to curl like https://foo.company.com/api/whatever
# -Method: GET, PUT, POST...
# -Authorization: authentication like Basic encoded64String or Bearer bearerToken
# -accept: what kind of format you want, like application/xml or */*

# Prepare for a graceful (or not) exit in case of error in the curl
trap "exit 1" TERM
export TOP_PID=$$
CatchInvokeRestMethodErrors() {
    
    # Get the parameters with names
    while [[ "$#" -gt 0 ]]
    do
        case $1 in
            -uri)
                local uri="$2"
            ;;
            -Method)
                local Method="$2"
            ;;
            -Authorization)
                local Authorization="$2"
            ;;
            -accept)
                local accept="$2"
            ;;
        esac
        shift
    done
    
    # Curl the request adding the http code at the end (last 3 characters)
    httpResponse=$(curl -s -w '%{http_code}' -X "$Method" "$uri" -H "accept: $accept" -H "Authorization: $Authorization") 
    
    # Get the http error code
    httpStatus=${httpResponse: -3}
    
    # Check the error code, if not 200, say it and stop
    if [ ! "$httpStatus" -eq 200 ]; then
        echo "It seems we cannot get data from your server, please check the variables in your script or the credentials used" >&2
        echo "URL: $uri" >&2
        echo "StatusCode: $httpStatus" >&2
        echo "Good Bye..." >&2
        kill -s TERM "$TOP_PID"
    else
        # If 200, then send back the rest of the respons without last 3 characters (remember, the http code)
        echo "${httpResponse%???}"
    fi
}
##### Function CatchInvokeRestMethodErrors #####

# This is to display or not an empty line later...
askedForLine=0

# If the variables are not modified, let's ask for information directly
if [[ -z "$serverURL" ]]; then
    echo -e "Please enter your Jamf Pro URL (include https:// and :port if needed): \c"
    read -r serverURL
    echo "The URL you typed is: $serverURL"
    echo
    askedForLine=1
fi

# Remove final / or other non alphanumerical character at the end of URL (and keep removing until there is none left)
while [[ ! "$serverURL" =~ [A-Za-z0-9]$ ]]; do
    serverURL=${serverURL%?}
done

# If the variables are not modified, let's ask for information directly
if [[ -z "$userName" ]]; then
    echo -e "Please enter your Jamf Pro username: \c"
    read -r userName
    echo "The username you typed is: $userName"
    echo   
    askedForLine=1
fi

# If the variables are not modified, let's ask for information directly
if [[ -z "$userPasswd" ]]; then
    echo -e "Please enter your Jamf Pro password: \c"
    read -rs userPasswd
    echo ""
    echo "The password you typed is: NO, I won't show..."
    echo
    askedForLine=1
fi

# Let's ask for the search string if nothing is passed as an argument
if [ -z "$1" ]; then
    echo -e "What string do you want to search in your scripts (press Enter to search for python): \c"
    read -r searchString
    if [ -z "$searchString" ]; then
        searchString="python"
    fi
    echo "The search string is: $searchString"
    echo
    askedForLine=1
else
    searchString="$1"
fi

# Make an empty line if we asked for the command to search
if [[  "$askedForLine" == 1 ]]; then
    echo ""
fi

## Get Jamf Pro version to use token auth if >= 10.35
jamfProVersion=$(CatchInvokeRestMethodErrors -uri "$serverURL/JSSCheckConnection" -Method GET -Authorization "foo" -accept "*/*" | awk -F"." '{ print $1$2 }')

# Encode username and password to use Basic Authorization
encodedAuthorization=$(printf '%s' "$userName:$userPasswd" | /usr/bin/iconv -t ISO-8859-1 | base64)

# Based on Jamf Pro version get a bearer token or use basic auth
if [[ "$jamfProVersion" -ge 1035 ]]; then
    bearerToken=$(CatchInvokeRestMethodErrors -uri "$serverURL/api/v1/auth/token" -accept "application/json" -Authorization "Basic $encodedAuthorization" -Method "POST" | plutil -extract token raw -o - - ) 
    authorizationString="Bearer $bearerToken"
else
    authorizationString="Basic $encodedAuthorization"
fi

###################################################################################

countEAsFound=0

# Get a list of all the extension attributes
allEAs=$(CatchInvokeRestMethodErrors -uri "$serverURL/JSSResource/computerextensionattributes" -Method "GET" -accept "application/xml" -Authorization "$authorizationString")

if [[ $(echo "$allEAs" | grep -ic "xml") -eq 0 ]] ; then
    echo "It seems we cannot get data from your server, please check the variables in your script or the credentials used"
    exit
fi

# XSLT to transform the XML make a list of extension attributes IDs
XSLT='<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
<xsl:output method="text"/>
<xsl:template match="/">
<xsl:for-each select="computer_extension_attributes/computer_extension_attribute">
<xsl:value-of select="id"/>
<xsl:text>&#xa;</xsl:text>
</xsl:for-each>
</xsl:template>
</xsl:stylesheet>'

allEAsID=$(echo "$allEAs" | xsltproc <(echo "$XSLT") -)

countEAs=$(echo "$allEAs" | xmllint --xpath '/computer_extension_attributes/size/text()' -)

# If we have 0 extension attribute, either there is an issue or we don't need that script
# If more than 0, get the correct plural version if needed
if [[ "$countEAs" == 0 ]]; then
    echo "You don't have any extension attributes in your Jamf Pro instance or we cannot connect, good bye"
    exit 0
elif [[ "$countEAs" == 1 ]]; then
    countEAsName="extension attribute"
else
    countEAsName="extension attributes"
fi

# Inform you
echo "You have $countEAs $countEAsName in your instance of Jamf Pro"
echo "We are looking for: $searchString"
echo ""

while read -r extensionAttributeID; do
    
    # Get the full content of the extension attribute
    extensionAttributeFullInfo=$(CatchInvokeRestMethodErrors -uri "$serverURL/JSSResource/computerextensionattributes/id/$extensionAttributeID" -Method "GET" -accept "application/xml" -Authorization "$authorizationString")
    
    # Get the decoded version of the script itself
    extensionAttributeContentDecoded=$(echo "$extensionAttributeFullInfo" | xmllint --xpath 'string(//computer_extension_attribute/input_type/script)' -)
    
    # Decode the script and search for the number of occurrences of the command
    extensionAttributeContentSearch=$(echo "$extensionAttributeContentDecoded" | grep -c "$searchString")
    
    # If there is at least 1 occurrences of the command, let's go
    if [[ "$extensionAttributeContentSearch" -gt 0 ]]; then
        
        # Get the name of the script
        extensionAttributeName=$(echo "$extensionAttributeFullInfo" | xmllint --xpath 'string(//computer_extension_attribute/name)' -)
        
        # Get line numbers showing the searched string, all in one line, separated with spaces
        extensionAttributeLineNumbers=$(echo "$extensionAttributeContentDecoded" | grep -n "$searchString" | awk -F":" '{ print $1 }' | tr '\n' ' ')
        
        # If more than 0, get the correct plural version if needed
        if [[ "$extensionAttributeContentSearch" == 1 ]]; then
            occurenceName="occurrence"
            lineNumbersName="Line that has"
        else
            occurenceName="occurrences"
            lineNumbersName="Lines that have"
        fi
        
        # Let's tell you what we found
        echo "The extension attribute called \"$extensionAttributeName\" contains $extensionAttributeContentSearch $occurenceName of \"$searchString\""
        echo "Extension attribute ID is: $extensionAttributeID"
        echo "Extension attribute URL is: $serverURL/computerExtensionAttributes.html?id=$extensionAttributeID"
        echo "$lineNumbersName \"$searchString\": $extensionAttributeLineNumbers"
        echo ""

        ((countEAsFound++))        
    fi
    
done <<< "$allEAsID"

if [[ "$countEAsFound" -eq 1 ]]; then
    countEAsFoundName="extension attribute"
else
    countEAsFoundName="extension attributes"
fi

echo ""
echo "Search is finished, happy $countEAsFoundName reviewing"
