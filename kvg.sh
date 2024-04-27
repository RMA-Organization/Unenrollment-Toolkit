#!/bin/bash

echo "KVG: KERNEL VERSION GENERATOR"
echo "MADE BY PEAP"
echo "ORIGINALLY MADE BY KXTZOWNSU"
echo "LICENSED UNDER THE AGPLv3"
echo "-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
read -p "Enter the kernel version you would like to use: " input
echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-"

    # Remove "0x" prefix
input=${input#"0x"}

    # Reverse the string
reversed=$(echo "$input" | rev)

    # Insert spaces every two characters
spaced=$(echo "$reversed" | sed 's/../& /g')

hex_input="02 4c 57 52 47 aa aa aa 00 00 00 00 74"
echo "$hex_input" > kernver
echo "Here is your kernver in hex:"
echo "$hex_input"