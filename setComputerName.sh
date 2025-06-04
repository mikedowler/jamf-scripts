#!/bin/zsh

/usr/local/bin/jamf setComputerName -prefix "L-" -useSerialNumber
wait 3
echo "New computer name: $( /usr/local/bin/jamf getComputerName )"