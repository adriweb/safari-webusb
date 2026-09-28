// Deterministic in-memory USB transport. Never links libusb or accesses hardware.
#include "FakeUSB.h"
#include <libusb.h>
#include <stdlib.h>
#include <string.h>

struct libusb_device { int refs; };
struct libusb_device_handle { int configuration; };
struct libusb_context { int unused; };
static struct libusb_device devices[2];
static struct libusb_context context;
static int generation, handles, calls, claims, transfer_result;
static bool connected = true;
static bool protected_class;
static const struct libusb_endpoint_descriptor endpoints[] = {
    {.bEndpointAddress = 0x81, .bmAttributes = LIBUSB_TRANSFER_TYPE_BULK, .wMaxPacketSize = 64},
    {.bEndpointAddress = 0x01, .bmAttributes = LIBUSB_TRANSFER_TYPE_BULK, .wMaxPacketSize = 64},
    {.bEndpointAddress = 0x82, .bmAttributes = LIBUSB_TRANSFER_TYPE_INTERRUPT, .wMaxPacketSize = 16}
};
static const struct libusb_endpoint_descriptor alt_endpoint = {
    .bEndpointAddress = 0x83, .bmAttributes = LIBUSB_TRANSFER_TYPE_BULK, .wMaxPacketSize = 64
};
static struct libusb_interface_descriptor alternates[] = {
    {.bInterfaceNumber = 0, .bAlternateSetting = 0, .bInterfaceClass = 0xff, .bNumEndpoints = 3, .endpoint = endpoints},
    {.bInterfaceNumber = 0, .bAlternateSetting = 1, .bInterfaceClass = 0xff, .bNumEndpoints = 1, .endpoint = &alt_endpoint}
};
static struct libusb_interface_descriptor second = {.bInterfaceNumber = 1, .bInterfaceClass = 0xff};
static const struct libusb_interface interfaces[] = {
    {.altsetting = alternates, .num_altsetting = 2}, {.altsetting = &second, .num_altsetting = 1}
};
void fake_usb_protected(bool value) { protected_class = value; }
void fake_usb_all_protected(bool value) {
    protected_class = value;
    alternates[0].bInterfaceClass = value ? 3 : 0xff;
    alternates[1].bInterfaceClass = value ? 3 : 0xff;
}
void fake_usb_connected(bool value) { if (value && !connected) generation = 1 - generation; connected = value; }
void fake_usb_transfer_result(int result) { transfer_result = result; }
int fake_usb_open_handles(void) { return handles; }
int fake_usb_transfer_calls(void) { return calls; }
int fake_usb_claim_calls(void) { return claims; }
int fake_usb_ref_balance(void) { return devices[0].refs + devices[1].refs; }
int libusb_init(libusb_context **ctx) { *ctx = &context; return 0; }
void libusb_exit(libusb_context *ctx) { (void)ctx; }
libusb_device *libusb_ref_device(libusb_device *dev) { dev->refs++; return dev; }
void libusb_unref_device(libusb_device *dev) { dev->refs--; }
ssize_t libusb_get_device_list(libusb_context *ctx, libusb_device ***list) {
    (void)ctx;
    *list = calloc(2, sizeof(libusb_device *));
    if (connected) (*list)[0] = libusb_ref_device(&devices[generation]);
    return connected ? 1 : 0;
}
void libusb_free_device_list(libusb_device **list, int unref) {
    if (unref && list[0]) libusb_unref_device(list[0]);
    free(list);
}
int libusb_get_device_descriptor(libusb_device *dev, struct libusb_device_descriptor *desc) {
    (void)dev;
    *desc = (struct libusb_device_descriptor){.bcdUSB = 0x0200, .bcdDevice = 0x0123, .idVendor = 0x0451, .idProduct = 0xe008, .bNumConfigurations = 2};
    return 0;
}
int libusb_get_config_descriptor(libusb_device *dev, uint8_t index, struct libusb_config_descriptor **desc) {
    (void)dev;
    if (index > 1) return LIBUSB_ERROR_NOT_FOUND;
    second.bInterfaceClass = protected_class ? 3 : 0xff;
    *desc = calloc(1, sizeof(**desc));
    **desc = (struct libusb_config_descriptor){.bConfigurationValue = index + 1, .bNumInterfaces = index ? 1 : 2, .interface = interfaces};
    return 0;
}
int libusb_get_config_descriptor_by_value(libusb_device *dev, uint8_t value, struct libusb_config_descriptor **desc) {
    if (!value) return LIBUSB_ERROR_NOT_FOUND;
    return libusb_get_config_descriptor(dev, value - 1, desc);
}
void libusb_free_config_descriptor(struct libusb_config_descriptor *desc) { free(desc); }
int libusb_open(libusb_device *dev, libusb_device_handle **handle) {
    (void)dev;
    *handle = calloc(1, sizeof(**handle)); (*handle)->configuration = 1; handles++; return 0;
}
void libusb_close(libusb_device_handle *handle) { handles--; free(handle); }
int libusb_get_configuration(libusb_device_handle *handle, int *configuration) { *configuration = handle->configuration; return 0; }
int libusb_set_configuration(libusb_device_handle *handle, int configuration) { handle->configuration = configuration; return 0; }
int libusb_claim_interface(libusb_device_handle *handle, int number) { (void)handle; (void)number; claims++; return 0; }
int libusb_release_interface(libusb_device_handle *handle, int number) { (void)handle; (void)number; return 0; }
int libusb_set_interface_alt_setting(libusb_device_handle *handle, int number, int alternate) { (void)handle; (void)number; (void)alternate; return 0; }
int libusb_reset_device(libusb_device_handle *handle) { (void)handle; return 0; }
int libusb_clear_halt(libusb_device_handle *handle, unsigned char endpoint) { (void)handle; (void)endpoint; return 0; }
static int transfer(unsigned char endpoint, unsigned char *data, int length, int *transferred, unsigned int timeout) {
    if (timeout != 5000) abort();
    calls++;
    *transferred = transfer_result ? 0 : (length < 4 ? length : 4);
    if (endpoint & 0x80) for (int i = 0; i < *transferred; i++) data[i] = (unsigned char)(i + 1);
    return transfer_result;
}
int libusb_bulk_transfer(libusb_device_handle *handle, unsigned char endpoint, unsigned char *data, int length, int *transferred, unsigned int timeout) {
    (void)handle; return transfer(endpoint, data, length, transferred, timeout);
}
int libusb_interrupt_transfer(libusb_device_handle *handle, unsigned char endpoint, unsigned char *data, int length, int *transferred, unsigned int timeout) {
    (void)handle; return transfer(endpoint, data, length, transferred, timeout);
}
int libusb_control_transfer(libusb_device_handle *handle, uint8_t type, uint8_t request, uint16_t value, uint16_t index, unsigned char *data, uint16_t length, unsigned int timeout) {
    (void)handle; (void)request; (void)value; (void)index;
    int transferred = 0, result = transfer(type, data, length, &transferred, timeout);
    return result < 0 ? result : transferred;
}
int libusb_get_string_descriptor_ascii(libusb_device_handle *handle, uint8_t index, unsigned char *data, int length) {
    (void)handle; (void)index; (void)data; (void)length; return 0;
}
const char *libusb_error_name(int error) { (void)error; return "FAKE_USB_ERROR"; }
