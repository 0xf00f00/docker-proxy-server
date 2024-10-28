#!/bin/bash

set -e

INTERFACE="ens3"
DOMAINS=("client1_dynamic_domain" "client2_dynamic_domain")
PREV_IP_FILE="/var/run/update_routes.prev"

# Get the default gateway for the interface
GATEWAY=$(ip route | awk "/default via .* dev $INTERFACE/{print \$3}")

if [ -z "$GATEWAY" ]; then
    echo "No default gateway found for interface $INTERFACE"
    exit 1
fi

declare -A PREV_IPS

# Load previous IPs if the file exists
if [ -f "$PREV_IP_FILE" ]; then
    while read -r line; do
        DOMAIN=$(echo "$line" | cut -d' ' -f1)
        IPS=$(echo "$line" | cut -d' ' -f2-)
        PREV_IPS["$DOMAIN"]="$IPS"
    done < "$PREV_IP_FILE"
fi

declare -A NEW_IPS

for DOMAIN in "${DOMAINS[@]}"; do
    # Resolve the IP addresses
    IPS=$(getent ahosts "$DOMAIN" | awk '/^[0-9]/{print $1}' | uniq | xargs)
    if [ -z "$IPS" ]; then
        echo "Failed to resolve $DOMAIN"
        continue
    fi
    NEW_IPS["$DOMAIN"]="$IPS"
done

# Update routes based on actual routing table
for DOMAIN in "${DOMAINS[@]}"; do
    NEW_IP_LIST=${NEW_IPS["$DOMAIN"]}
    if [ -z "$NEW_IP_LIST" ]; then
        continue
    fi

    # Convert IP lists to arrays
    read -a NEW_IP_ARRAY <<< "$NEW_IP_LIST"

    for IP in "${NEW_IP_ARRAY[@]}"; do
        # Check if route exists
        if ip route show "$IP" | grep -q "via $GATEWAY dev $INTERFACE"; then
            echo "Route already exists for $DOMAIN to IP $IP via $GATEWAY dev $INTERFACE"
        else
            echo "Adding route to IP $IP for $DOMAIN via gateway $GATEWAY"
            ip route add "$IP" via "$GATEWAY" dev "$INTERFACE"
        fi
    done
done

# Delete any routes that are no longer associated with the domains
# For each IP in PREV_IPS that is not in NEW_IPS, delete the route
for DOMAIN in "${DOMAINS[@]}"; do
    PREV_IP_LIST=${PREV_IPS["$DOMAIN"]}
    if [ -z "$PREV_IP_LIST" ]; then
        continue
    fi

    # Convert IP lists to arrays
    read -a PREV_IP_ARRAY <<< "$PREV_IP_LIST"
    NEW_IP_LIST=${NEW_IPS["$DOMAIN"]}
    read -a NEW_IP_ARRAY <<< "$NEW_IP_LIST"

    for IP in "${PREV_IP_ARRAY[@]}"; do
        if [[ ! " ${NEW_IP_ARRAY[@]} " =~ " ${IP} " ]]; then
            echo "Deleting route to old IP $IP for $DOMAIN"
            ip route del "$IP" via "$GATEWAY" dev "$INTERFACE" &>/dev/null || true
        fi
    done
done

# Save the new IPs to the file
mkdir -p "$(dirname "$PREV_IP_FILE")"
> "$PREV_IP_FILE"
for DOMAIN in "${DOMAINS[@]}"; do
    IPS=${NEW_IPS["$DOMAIN"]}
    if [ -n "$IPS" ]; then
        echo "$DOMAIN $IPS" >> "$PREV_IP_FILE"
    fi
done
