# Allowed address pair Extension

This extension verifies that your OpenStack supports virtual IP address failover with allowed address pairs

https://blog.codecentric.de/en/2016/11/highly-available-vips-openstack-vms-vrrp/

## Configuration

Create a `allow_address_pair.yml` and include two floating IPs from your OpenStack tenant.

```yaml
- floating_ip_1: "10.11.12.13"
  floating_ip_2: "10.11.12.14"
```

Add the extension to your `validator.yml`:

```yaml
extensions:
  paths: [./extensions/allowed_address_pair]
  config:
    allowed_address_pair
     expected_infrastructure: </absolute/path/to/allowed_address_pair.yml>
```
