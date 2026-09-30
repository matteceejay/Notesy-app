# Lightsail VM that runs the release bundle pulled from JFrog (the non-container deploy path).
# GitHub Actions SSHes in with the generated key, copies the bundle, and swaps releases.
# Caddy on the box terminates HTTPS for notesy-vm.handart.site and proxies to gunicorn on 127.0.0.1:8000.

resource "aws_lightsail_key_pair" "deploy" {
  name = "${var.app_name}-deploy"
}

resource "aws_lightsail_instance" "app" {
  name              = "${var.app_name}-vm"
  availability_zone = "${var.aws_region}a"
  blueprint_id      = "ubuntu_24_04"
  bundle_id         = var.lightsail_bundle_id
  key_pair_name     = aws_lightsail_key_pair.deploy.name
  user_data         = file("${path.module}/lightsail_user_data.sh")
}

resource "aws_lightsail_static_ip" "app" {
  name = "${var.app_name}-ip"
}

resource "aws_lightsail_static_ip_attachment" "app" {
  static_ip_name = aws_lightsail_static_ip.app.name
  instance_name  = aws_lightsail_instance.app.name
}

# cidrs / ipv6_cidrs are set explicitly: if left out, the provider treats them as unknown
# and plans a destroy/recreate of this resource on every run.
resource "aws_lightsail_instance_public_ports" "app" {
  instance_name = aws_lightsail_instance.app.name

  # GitHub-hosted runner IPs aren't fixed, so SSH is open; key-only auth.
  port_info {
    protocol   = "tcp"
    from_port  = 22
    to_port    = 22
    cidrs      = ["0.0.0.0/0"]
    ipv6_cidrs = ["::/0"]
  }

  # HTTP: Caddy redirects to HTTPS and answers Let's Encrypt challenges here.
  port_info {
    protocol   = "tcp"
    from_port  = 80
    to_port    = 80
    cidrs      = ["0.0.0.0/0"]
    ipv6_cidrs = ["::/0"]
  }

  # HTTPS: Caddy terminates TLS and proxies to gunicorn on 127.0.0.1:8000.
  port_info {
    protocol   = "tcp"
    from_port  = 443
    to_port    = 443
    cidrs      = ["0.0.0.0/0"]
    ipv6_cidrs = ["::/0"]
  }
}

variable "lightsail_bundle_id" {
  description = "Lightsail plan. List options with: aws lightsail get-bundles --query 'bundles[].bundleId'"
  type        = string
  default     = "small_3_0"
}

output "lightsail_host" {
  description = "GitHub variable LIGHTSAIL_HOST"
  value       = aws_lightsail_static_ip.app.ip_address
}

output "lightsail_ssh_private_key" {
  description = "GitHub secret LIGHTSAIL_SSH_KEY: terraform output -raw lightsail_ssh_private_key"
  value       = aws_lightsail_key_pair.deploy.private_key
  sensitive   = true
}