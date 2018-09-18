# Allowed address pair Extension
Allowed address pair verifies that virtual IP address failover is supported
https://blog.codecentric.de/en/2016/11/highly-available-vips-openstack-vms-vrrp/

## Configuration

Create a `allow_address_pair.yml` and include two floating IPs from your OpenStack tenant.

```yaml
---
- floating_ip_1: "10.17.140.134"
  floating_ip_2: "10.17.140.135"

Add the extension to your `validator.yml`:

```yaml
extensions:
  paths: [./extensions/allowed_address_pair]
  config:
    allowed_address_pair
     expected_infrastructure: </absolute/path/to/allowed_address_pair.yml>
```
