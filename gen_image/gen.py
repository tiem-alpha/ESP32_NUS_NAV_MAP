#!/usr/bin/env python3
"""
Convert ảnh thành mảng PROGMEM cho ESP32 (Arduino/ESP-IDF)
Output: File .h với mảng uint16_t hoặc uint8_t trong PROGMEM
"""

from PIL import Image
import argparse
import os
import sys

class ImageToPROGMEM:
    def __init__(self, image_path, output_path=None, width=240, height=320,
                 format_type="RGB565", array_name=None):
        self.image_path = image_path
        self.width = width
        self.height = height
        self.format_type = format_type
        
        # Tạo tên mảng
        if array_name is None:
            base = os.path.splitext(os.path.basename(image_path))[0]
            # Đảm bảo tên C hợp lệ
            array_name = base.replace('-', '_').replace(' ', '_').replace('.', '_')
            if array_name[0].isdigit():
                array_name = 'img_' + array_name
        self.array_name = array_name
        
        # Tạo tên file output
        if output_path is None:
            self.output_path = f"{array_name}.h"
        else:
            self.output_path = output_path
    
    def load_image(self):
        """Tải và xử lý ảnh"""
        print(f"Đang tải: {self.image_path}")
        img = Image.open(self.image_path)
        print(f"  Kích thước gốc: {img.size}, Mode: {img.mode}")
        
        # Resize
        if img.size != (self.width, self.height):
            print(f"  Resize về {self.width}x{self.height}...")
            img = img.resize((self.width, self.height), Image.Resampling.LANCZOS)
        
        return img
    
    def convert_to_rgb565_array(self, img):
        """Convert sang mảng uint16_t RGB565"""
        if img.mode != "RGB":
            img = img.convert("RGB")
        
        pixels = []
        for y in range(self.height):
            for x in range(self.width):
                r, g, b = img.getpixel((x, y))
                # RGB565 format
                rgb565 = ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)
                rgb565 = ((rgb565 & 0x00FF) << 8) | ((rgb565 & 0xFF00) >> 8)
                pixels.append(rgb565)
        
        return pixels, 'uint16_t'
    
    def convert_to_rgb888_array(self, img):
        """Convert sang mảng uint8_t RGB888"""
        if img.mode != "RGB":
            img = img.convert("RGB")
        
        pixels = []
        for y in range(self.height):
            for x in range(self.width):
                r, g, b = img.getpixel((x, y))
                pixels.extend([r, g, b])
        
        return pixels, 'uint8_t'
    
    def convert_to_argb8888_array(self, img):
        """Convert sang mảng uint8_t ARGB8888"""
        if img.mode != "RGBA":
            img = img.convert("RGBA")
        
        pixels = []
        for y in range(self.height):
            for x in range(self.width):
                r, g, b, a = img.getpixel((x, y))
                pixels.extend([a, r, g, b])  # LVGL dùng ARGB
        
        return pixels, 'uint8_t'
    
    def generate_header(self, img):
        """Tạo header file với mảng PROGMEM"""
        print(f"\nĐang tạo header: {self.output_path}")
        
        # Convert pixels
        if self.format_type == "RGB565":
            pixels, data_type = self.convert_to_rgb565_array(img)
            color_format = "LV_IMG_CF_TRUE_COLOR"
        elif self.format_type == "RGB888":
            pixels, data_type = self.convert_to_rgb888_array(img)
            color_format = "LV_IMG_CF_TRUE_COLOR_CHROMA_KEYED"
        elif self.format_type == "ARGB8888":
            pixels, data_type = self.convert_to_argb8888_array(img)
            color_format = "LV_IMG_CF_TRUE_COLOR_ALPHA"
        
        with open(self.output_path, 'w', encoding='utf-8') as f:
            # Header guard
            guard_name = f"{self.array_name.upper()}_H"
            f.write(f"#ifndef {guard_name}\n")
            f.write(f"#define {guard_name}\n\n")
            
            # Includes
            # f.write("#ifdef __has_include\n")
            # f.write("    #if __has_include(\"lvgl.h\")\n")
            # f.write("        #include \"lvgl.h\"\n")
            # f.write("    #else\n")
            # f.write("        #include \"lvgl/lvgl.h\"\n")
            # f.write("    #endif\n")
            # f.write("#else\n")
            # f.write("    #include \"lvgl.h\"\n")
            # f.write("#endif\n\n")
            
            # Nếu dùng Arduino
            # f.write("// Cho Arduino/ESP32\n")
            # f.write("#ifdef ARDUINO\n")
            # f.write("#include <Arduino.h>\n")
            # f.write("#endif\n\n")
            
            # Comment mô tả
            f.write(f"/**\n")
            f.write(f" * Image: {os.path.basename(self.image_path)}\n")
            f.write(f" * Size: {self.width}x{self.height}\n")
            f.write(f" * Format: {self.format_type}\n")
            f.write(f" * Data size: {len(pixels) * (2 if data_type == 'uint16_t' else 1)} bytes\n")
            f.write(f" */\n\n")
            
            # Khai báo mảng PROGMEM
            f.write(f"// Mảng dữ liệu ảnh lưu trong Flash\n")
            
            # PROGMEM cho AVR, DRAM_ATTR hoặc const cho ESP32
            # f.write("#if defined(ESP32) || defined(ESP8266)\n")
            # f.write(f"    // ESP32/ESP8266 tự động lưu const trong Flash\n")
            # f.write(f"    const {data_type} {self.array_name}_data[] PROGMEM = {{\n")
            # f.write("#elif defined(__AVR__)\n")
            # f.write(f"    // Arduino AVR cần PROGMEM rõ ràng\n")
            # f.write(f"    const {data_type} {self.array_name}_data[] PROGMEM = {{\n")
            # f.write("#else\n")
            f.write(f"    const {data_type} {self.array_name}_data[] = {{\n")
            # f.write("#endif\n")
            
            # Ghi dữ liệu pixel
            items_per_line = 12 if data_type == 'uint16_t' else 16
            
            for i in range(0, len(pixels), items_per_line):
                line_data = []
                for j in range(i, min(i + items_per_line, len(pixels))):
                    if data_type == 'uint16_t':
                        line_data.append(f"0x{pixels[j]:04X}")
                    else:
                        line_data.append(f"0x{pixels[j]:02X}")
                
                if i + items_per_line < len(pixels):
                    f.write(f"    {', '.join(line_data)},\n")
                else:
                    f.write(f"    {', '.join(line_data)}\n")
            
            f.write("};\n\n")
            
            # LVGL image descriptor
            f.write(f"// LVGL Image Descriptor\n")
            f.write(f"const lv_img_dsc_t {self.array_name} = {{\n")
            f.write(f"    .header.cf = {color_format},\n")
            f.write(f"    .header.always_zero = 0,\n")
            f.write(f"    .header.reserved = 0,\n")
            f.write(f"    .header.w = {self.width},\n")
            f.write(f"    .header.h = {self.height},\n")
            f.write(f"    .data_size = sizeof({self.array_name}_data),\n")
            f.write(f"    .data = (const uint8_t*){self.array_name}_data,\n")
            f.write("};\n\n")
            
            f.write(f"#endif // {guard_name}\n")
        
        # Thống kê
        data_size = len(pixels) * (2 if data_type == 'uint16_t' else 1)
        print(f"✓ Hoàn thành!")
        print(f"  File: {self.output_path}")
        print(f"  Array: {self.array_name}_data[{len(pixels)}]")
        print(f"  Type: {data_type}")
        print(f"  Data size: {data_size:,} bytes ({data_size/1024:.1f} KB)")
        print(f"  Size in Flash: {data_size:,} bytes")

def main():
    parser = argparse.ArgumentParser(
        description='Convert ảnh thành mảng PROGMEM cho ESP32',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Ví dụ sử dụng:
  python img2progmem.py image.jpg
  python img2progmem.py logo.png -n my_logo -f ARGB8888
  python img2progmem.py bg.jpg -w 320 -h 240 -o background.h
        """
    )
    
    parser.add_argument('image', help='File ảnh input')
    parser.add_argument('-o', '--output', help='File header output (.h)')
    parser.add_argument('-w', '--width', type=int, default=240,
                       help='Chiều rộng (mặc định: 240)')
    parser.add_argument('-H', '--height', type=int, default=320,
                       help='Chiều cao (mặc định: 320)')
    parser.add_argument('-f', '--format',
                       choices=['RGB565', 'RGB888', 'ARGB8888'],
                       default='RGB565',
                       help='Định dạng màu (mặc định: RGB565)')
    parser.add_argument('-n', '--name', 
                       help='Tên mảng (mặc định: từ tên file)')
    
    args = parser.parse_args()
    
    if not os.path.exists(args.image):
        print(f"Lỗi: Không tìm thấy file {args.image}")
        sys.exit(1)
    
    converter = ImageToPROGMEM(
        image_path=args.image,
        output_path=args.output,
        width=args.width,
        height=args.height,
        format_type=args.format,
        array_name=args.name
    )
    
    try:
        img = converter.load_image()
        converter.generate_header(img)
    except Exception as e:
        print(f"Lỗi: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)

if __name__ == "__main__":
    main()