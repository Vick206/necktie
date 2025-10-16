#!/usr/bin/env zsh

# Check if domain was provided
if [[ $# -eq 0 ]]; then
    echo "Usage: $0 domain.com"
    exit 1
fi

domain=$1
record_types=(A AAAA CNAME MX TXT NS SOA SRV PTR DNSKEY DS NAPTR)

echo "Querying DNS records for: $domain"
echo "==================================="

# Function to query DNS records
query_dns() {
    local record_type=$1
    echo "\n[${record_type} Records]"
    dig +short $domain $record_type | while read -r line; do
        echo "  $line"
    done
}

# Query each record type
for type in $record_types; do
    query_dns $type
done

echo "\nDNS record query completed."
