#!/bin/sh

cp /root/haproxy/haproxy.cfg /root/haproxy_data/haproxy.cfg
echo ${WEB_DOMAINS} | tr ', ' '\n' > /root/haproxy_data/web_domains.lst