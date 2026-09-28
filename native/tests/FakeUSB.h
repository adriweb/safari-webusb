#pragma once
#include <stdbool.h>
void fake_usb_protected(bool protected_interface);
void fake_usb_all_protected(bool protected_interfaces);
void fake_usb_connected(bool connected);
void fake_usb_transfer_result(int result);
int fake_usb_open_handles(void);
int fake_usb_transfer_calls(void);
int fake_usb_claim_calls(void);
int fake_usb_ref_balance(void);
