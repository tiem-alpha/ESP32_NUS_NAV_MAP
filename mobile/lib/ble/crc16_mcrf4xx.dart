/// CRC-16/MCRF4XX.
///
/// Parameters: poly 0x1021, init 0xFFFF, refin/refout true, xorout 0x0000.
/// The reflected step uses reversed polynomial 0x8408, matching the firmware
/// table implementation in `crc16_cal`.
const int crc16Mcrf4xxInitialValue = 0xFFFF;

int crc16Mcrf4xx(List<int> data, [int start = 0, int? end]) {
  return crc16Mcrf4xxUpdate(crc16Mcrf4xxInitialValue, data, start, end);
}

int crc16Mcrf4xxUpdate(int crc, List<int> data, [int start = 0, int? end]) {
  end ??= data.length;
  var value = crc & 0xFFFF;
  for (var i = start; i < end; i++) {
    value ^= data[i] & 0xFF;
    for (var bit = 0; bit < 8; bit++) {
      if ((value & 0x0001) != 0) {
        value = (value >> 1) ^ 0x8408;
      } else {
        value >>= 1;
      }
      value &= 0xFFFF;
    }
  }
  return value & 0xFFFF;
}
