#!/bin/bash
# firewall.sh - Configure IPv4 firewall rules and drop all IPv6 traffic.
#
# This script performs the following actions:
#   1. Flushes existing IPv4 and IPv6 rules.
#   2. Sets default policies (INPUT/DROP for IPv4 and DROP for all IPv6 chains).
#   3. Allows loopback traffic, established/related IPv4 connections, and specific ports (22, 80, 443, 8080).
#   4. Drops all IPv6 traffic.
#   5. Saves rules using iptables-persistent if installed; otherwise, it warns the user.
#
# NOTE: To persist these settings across reboots, ensure the iptables-persistent
#       package is installed (e.g., via "sudo apt install iptables-persistent").

# Ensure the script is run as root.
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Use sudo."
    exit 1
fi

###############################
# IPv4 Configuration
###############################

echo "Flushing existing IPv4 iptables rules..."
iptables -F      # Flush all IPv4 rules.
iptables -X      # Delete any IPv4 user-defined chains.
iptables -Z      # Zero all IPv4 packet and byte counters.

echo "Setting default IPv4 policies..."
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

echo "Allowing loopback traffic (IPv4)..."
iptables -A INPUT -i lo -j ACCEPT

echo "Allowing established and related IPv4 connections..."
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

echo "Allowing incoming SSH (port 22, IPv4)..."
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

echo "Allowing incoming HTTP (port 80, IPv4)..."
iptables -A INPUT -p tcp --dport 80 -j ACCEPT

echo "Allowing incoming HTTPS (port 443, IPv4)..."
iptables -A INPUT -p tcp --dport 443 -j ACCEPT

echo "Allowing incoming connections on port 8080 (IPv4)..."
iptables -A INPUT -p tcp --dport 8080 -j ACCEPT

###############################
# IPv6 Configuration
###############################

echo "Flushing existing IPv6 ip6tables rules..."
ip6tables -F     # Flush all IPv6 rules.
ip6tables -X     # Delete any IPv6 user-defined chains.
ip6tables -Z     # Zero all IPv6 packet and byte counters.

echo "Setting default IPv6 policies to DROP all traffic..."
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT DROP

###############################
# Save Rules if Possible
###############################

if dpkg -s iptables-persistent >/dev/null 2>&1; then
    echo "Saving IPv4 rules to /etc/iptables/rules.v4..."
    iptables-save > /etc/iptables/rules.v4

    echo "Saving IPv6 rules to /etc/iptables/rules.v6..."
    ip6tables-save > /etc/iptables/rules.v6

    echo "Firewall rules have been saved with iptables-persistent."
else
    echo "Warning: iptables-persistent is not installed." >&2
    echo "Firewall rules will not persist after reboot." >&2
fi


###############################
# Display Current Rules
###############################

echo -e "\nIPv4 iptables rules (verbose, numerical, with line numbers):"
iptables -L -v -n --line-numbers

echo -e "\nIPv6 ip6tables rules (verbose, numerical, with line numbers):"
ip6tables -L -v -n --line-numbers

echo -e "\nFirewall rules have been applied and displayed above."