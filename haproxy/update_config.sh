#!/bin/sh

cp /root/haproxy/haproxy.cfg /root/haproxy_data/haproxy.cfg
# echo ${SHADOWTLS_DOMAINS} | sed 's/:[0-9]\+//g' | tr ';' '\n' > /root/haproxy_data/shadowtls_domains.lst
echo ${WEB_DOMAINS} | tr ', ' '\n' > /root/haproxy_data/web_domains.lst