using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace AddonUpdater {
    public static class ArchiveTools {
        static readonly uint[] Table = CreateTable();
        static uint[] CreateTable() {
            uint[] table = new uint[256];
            for (uint n = 0; n < 256; n++) { uint c = n; for (int k=0;k<8;k++) c = (c & 1) != 0 ? 0xedb88320U ^ (c >> 1) : c >> 1; table[n] = c; }
            return table;
        }
        public static uint Copy(Stream input, Stream output) {
            uint crc = 0xffffffffU; byte[] buffer = new byte[131072]; int count;
            while ((count=input.Read(buffer,0,buffer.Length))>0) {
                output.Write(buffer,0,count);
                for(int i=0;i<count;i++) crc=Table[(crc ^ buffer[i]) & 255] ^ (crc >> 8);
            }
            return crc ^ 0xffffffffU;
        }
        public static Dictionary<string,uint> Crcs(string file) {
            using (FileStream stream=File.OpenRead(file)) using (BinaryReader reader=new BinaryReader(stream)) {
                long end=-1;
                for(long p=stream.Length-22;p>=Math.Max(0,stream.Length-65557);p--) {
                    stream.Position=p;
                    if(reader.ReadUInt32()!=0x06054b50) continue;
                    stream.Position=p+20;
                    if(p+22+reader.ReadUInt16()==stream.Length){end=p;break;}
                }
                if(end<0) throw new InvalidDataException("Invalid ZIP directory.");
                stream.Position=end+4;
                if(reader.ReadUInt16()!=0 || reader.ReadUInt16()!=0) throw new InvalidDataException("Multi-volume ZIPs are not supported.");
                reader.ReadUInt16(); ushort count=reader.ReadUInt16(); reader.ReadUInt32(); uint offset=reader.ReadUInt32();
                if(count==65535 || offset==uint.MaxValue) throw new InvalidDataException("ZIP64 packages require manual installation.");
                stream.Position=offset;
                Dictionary<string,uint> result=new Dictionary<string,uint>(StringComparer.OrdinalIgnoreCase);
                for(int i=0;i<count;i++) {
                    if(reader.ReadUInt32()!=0x02014b50) throw new InvalidDataException("Invalid ZIP entry.");
                    reader.ReadUInt16(); reader.ReadUInt16(); ushort flags=reader.ReadUInt16(); ushort method=reader.ReadUInt16();
                    reader.ReadUInt32(); uint crc=reader.ReadUInt32(); reader.ReadUInt32(); reader.ReadUInt32();
                    ushort nameLength=reader.ReadUInt16(),extra=reader.ReadUInt16(),comment=reader.ReadUInt16();
                    reader.ReadUInt16();reader.ReadUInt16();uint attrs=reader.ReadUInt32();reader.ReadUInt32();
                    string name=((flags & 2048)!=0?Encoding.UTF8:Encoding.GetEncoding(437)).GetString(reader.ReadBytes(nameLength));
                    if((flags & 1)!=0 || (method!=0 && method!=8) || ((attrs >> 16) & 0xf000)==0xa000) throw new InvalidDataException("Unsupported/encrypted/linked ZIP entry: "+name);
                    result.Add(name,crc); stream.Seek(extra+comment,SeekOrigin.Current);
                }
                return result;
            }
        }
    }
}
