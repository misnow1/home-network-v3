# Domain glossary

Terms used across home-network-v3 documentation and runbooks.

## Lease-driven DDNS

Dynamic DNS updates triggered by DHCP lease lifecycle events (add, renew/old, delete) rather than by a client running `nsupdate` locally.

## DDNS API

An HTTP service on the domain controller that accepts lease notifications and performs authenticated dynamic DNS updates (GSS-TSIG `nsupdate`) on behalf of DHCP hosts that cannot run Kerberos themselves.

## dnsmasq hook

A thin `dhcp-script` handler on the DHCP server (production router or lab libvirt dnsmasq) that forwards lease events to the DDNS API. It does not perform DNS updates itself.
