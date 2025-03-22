#!/bin/bash

# Prompt the user for the number of passwords
read -p "Enter the number of passwords to generate: " count

# Validate input: it must be a positive integer
if ! [[ "$count" =~ ^[1-9][0-9]*$ ]]; then
  echo "Invalid input. Please enter a positive integer."
  exit 1
fi

echo "Generating $count secure passwords..."

for (( i=1; i<=count; i++ )); do
  # Generate a random length between 32 and 64 characters
  # RANDOM % 33 gives a number from 0 to 32, then add 32 to get 32-64.
  char_length=$(( RANDOM % 33 + 32 ))
  
  # Generate a password with only alphanumeric characters.
  # This reads from /dev/urandom, deletes all characters except A-Za-z0-9,
  # and then takes the first $char_length characters.
  password=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$char_length")
  
  # Output the password as an export statement for easy sourcing
  echo "export PASSWORD_$i=\"$password\""
done