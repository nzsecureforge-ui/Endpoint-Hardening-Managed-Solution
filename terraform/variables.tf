# Rollout-stage gates for the three OS-type target groups in groups.tf. Each defaults to
# false so a brand-new customer engagement always starts in the static/manual pilot-
# expansion tier and can never accidentally provision straight into production-wide dynamic
# enforcement. Flip one to true only after that platform's static group (Intune-Target-<X>)
# has run clean through the engagement's agreed soak period — see ../README.md
# "Rollout model" for the full Pilot -> Static -> Dynamic narrative and why promotion
# provisions a second group rather than converting the static one in place.
#
# These are genuinely Terraform inputs (unlike the customer-identity values in
# ../config/customer.config.psd1, which the PowerShell deploy script reads directly) because
# they gate which Terraform resources exist at all. Copy terraform.tfvars.example to
# terraform.tfvars per customer engagement to set them.

variable "windows_workstations_dynamic" {
  description = "Provisions azuread_group.target_windows_workstations_dynamic (Intune-Target-WindowsWorkstations-Dynamic) alongside the always-present static group. See file-level comment above."
  type        = bool
  default     = false
}

variable "macos_dynamic" {
  description = "Provisions azuread_group.target_macos_dynamic (Intune-Target-macOS-Dynamic) alongside the always-present static group. See file-level comment above."
  type        = bool
  default     = false
}

variable "linux_dynamic" {
  description = "Provisions azuread_group.target_linux_dynamic (Intune-Target-Linux-Dynamic) alongside the always-present static group. See file-level comment above."
  type        = bool
  default     = false
}
