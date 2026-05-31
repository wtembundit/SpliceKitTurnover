# Turnover Tools Guide

คู่มือเครื่องมือหลักใน Turnover สำหรับงาน VFX turnover บน Final Cut Pro ผ่าน SpliceKit plugin

> สถานะปัจจุบัน: เครื่องมือชุดนี้ใช้งานได้กับ workflow ที่ทดสอบแล้ว แต่ยังมี edge cases จาก FCPXML บางรูปแบบที่ต้องไล่แก้ต่อ โดยเฉพาะ retime/speed ramp ซับซ้อน, nested sync clip, title ที่พาดข้ามหลายคลิป, marker, transform และ metadata ใน timeline ที่มีโครงสร้างแปลก

## 🎞 Conform Prep

เตรียม timeline สำหรับ conform โดยพยายาม flatten `sync-clip` ให้กลายเป็น original source clip ที่อ่านง่ายขึ้นใน timeline ปลายทาง

อ่านรายละเอียดเชิงลึกได้ที่ [Conform Prep Guide](./conform-prep.md)

เหมาะกับ:

- Timeline ที่มี `sync-clip` จำนวนมากและต้องการถอดกลับมาเป็น source-backed clip
- งาน VFX turnover ที่ต้องการให้ source filename, visible source timecode, title, marker, transform และ metadata ตามกลับมาให้มากที่สุด
- เคสที่ editor ใช้ retime บน sync clip และ/หรือ original clip ด้านใน

สิ่งที่ทำ:

- Flatten simple sync clips เป็น `clip` หรือ `asset-clip` ที่อ้างอิง source เดิม
- รวม speed ชั้นนอกกับ speed ของ original clip ด้านในเมื่อทำได้
- พยายาม preserve speed segment, speed transition/ramp, reverse, blade speed, title, marker, transform และ metadata
- Normalize offset/duration ให้ FCP import ได้และลด warning เรื่อง edit frame boundary
- สร้าง report เพื่อดูว่า flatten อะไรสำเร็จหรือ skip อะไรไว้

ข้อควรระวัง:

- ยังไม่รับประกันทุก FCPXML shape โดยเฉพาะ multicam และ retime pattern ที่ไม่เคยเจอ
- ถ้า import แล้วคลิปหายหรือ title/marker drift ให้เก็บ original XML และ output XML ไว้เป็นเคสทดสอบ

## 📝 VFX Auto Naming

เติมเลข shot ให้ title ประเภท `VFX NAMING` อัตโนมัติ

เหมาะกับ:

- Timeline ที่มี placeholder เช่น `ABC_SC99_XXXX`
- ต้องการเลข shot ต่อเนื่อง เช่น `0010`, `0020`, `0030`
- ต้องการเริ่มเลขใหม่เมื่อ scene prefix เปลี่ยน

สิ่งที่ทำ:

- อ่าน title ที่ใช้ Motion template `VFX NAMING`
- หา pattern ที่ลงท้ายด้วย placeholder `XXXX`
- แทนที่ placeholder ด้วยเลข shot แบบ running number
- Import project ใหม่กลับเข้า Final Cut Pro พร้อมชื่อ prefix ของ workflow

ตัวอย่าง:

```text
ABC_SC99_XXXX  ->  ABC_SC99_0010
ABC_SC99_XXXX  ->  ABC_SC99_0020
ABC_SC100_XXXX ->  ABC_SC100_0010
```

## 🔁 VFX Reset Naming

รีเซ็ตเลข shot ใน `VFX NAMING` titles กลับไปเป็น `XXXX`

เหมาะกับ:

- ต้องการ renumber timeline ใหม่ทั้งหมด
- ทดลองเลข shot แล้วอยากย้อนกลับเป็น placeholder
- Timeline เปลี่ยนลำดับจนเลขเดิมไม่ถูกต้องแล้ว

สิ่งที่ทำ:

- อ่าน title ที่มีเลข shot อยู่แล้ว เช่น `ABC_SC99_0010`
- เปลี่ยนเฉพาะส่วนเลข shot กลับเป็น `XXXX`
- ไม่แตะ prefix/scene ที่อยู่ด้านหน้า

ตัวอย่าง:

```text
ABC_SC99_0010 -> ABC_SC99_XXXX
ABC_SC99_0020 -> ABC_SC99_XXXX
```

## 🛠 VFX Auto Marker

สร้าง marker จาก `VFX NAMING` titles เพื่อใช้ต่อกับ shot list และ pull workflow

เหมาะกับ:

- Timeline ที่ naming พร้อมแล้ว
- ต้องการ marker เป็นจุดอ้างอิงสำหรับ VFX shot
- ต้องการเลือกชนิด marker ตามการใช้งานใน Final Cut Pro

Marker types:

- `Standard`: marker ปกติ
- `To Do`: marker สำหรับรายการงานที่ต้อง follow up
- `Chapter`: marker แบบ chapter

สิ่งที่ทำ:

- ให้เลือก marker type จากเมนู Turnover
- อ่าน VFX number จาก title
- ใส่ VFX number ลง marker name
- ใส่ description/note ลง marker note
- วาง marker ตามตำแหน่ง title เพื่อให้ workflow อื่นใช้ต่อได้

## 📋 VFX Shot List

สร้าง Excel shot list พร้อม thumbnail จาก timeline ปัจจุบัน

เหมาะกับ:

- ส่งรายการ VFX ให้ vendor/post house
- ต้องการ thumbnail ประกอบแต่ละ shot
- ต้องการ timeline TC, source TC, filename, metadata และ remark ในไฟล์เดียว

ผลลัพธ์:

```text
Desktop/
  VFX Shot List - <Project Name>/
    VFX Shot List - <Project Name>.xlsx
    Thumbnails/
```

คอลัมน์หลัก:

- Thumbnail
- VFX Number
- Note
- Timeline TC In
- Duration (Frames)
- Source Filename
- Source TC In
- Source TC Out
- Metadata
- Remark

วิธี capture thumbnail:

- Turnover ใช้ native plugin capture หน้าต่าง Final Cut Pro ที่ใหญ่ที่สุด
- ถ้าต้องการ thumbnail จาก fullscreen preview ให้เปิด fullscreen preview ไว้ก่อน run
- ต้องให้ Screen Recording permission กับ Final Cut Pro/SpliceKit process

ข้อควรระวัง:

- ถ้า macOS ยังไม่อนุญาต Screen Recording รูปอาจไม่ขึ้นหรือ capture ผิดหน้าต่าง
- ถ้า timeline มี overlapping clip ซับซ้อนมาก source range อาจต้องตรวจทานอีกครั้ง

## 🧾 VFX Pull EDL

สร้าง EDL สำหรับ pull source media ตาม VFX markers

เหมาะกับ:

- ต้องส่ง source range ให้ทีม online/VFX
- ต้องการ handle เพิ่มหัวท้าย
- มีหลาย layer ซ้อนกันใน shot เดียว

Handle frames:

- ค่าที่ใส่คือจำนวนเฟรมที่เพิ่มทั้งหัวและท้าย
- เช่น ใส่ `8` หมายถึงเพิ่ม head 8 frames และ tail 8 frames
- ไม่จำเป็นต้องเป็นเลขคู่

Layer naming:

- Source หลักใช้ `PL01`
- Source ที่ซ้อนเพิ่มใช้ `EL01`, `EL02`, ต่อไปเรื่อยๆ

ผลลัพธ์:

```text
VFX Pull EDL - <Project Name>.edl
```

## 📦 VFX Timeline

นำ VFX render ที่กลับมาจาก post ไปวางกลับบน timeline

เหมาะกับ:

- ได้ไฟล์ render จาก vendor แล้วต้องการ conform กลับลง timeline
- ต้องการวางแบบ connected clip, replace หรือ audition
- ต้องการ versioning เช่น v1, v2, v3

Modes:

- `Connected`: วาง render เป็น connected clip เหนือ timeline
- `Replace`: แทน VFX เดิม ถ้าไม่มีของเดิมจะ fallback เป็น connected
- `Audition`: สร้าง audition รวม version ใหม่ ถ้าไม่มีของเดิมจะ fallback เป็น connected

ผลลัพธ์:

```text
📦 VFX Deliveries v1 - <Project Name>
📦 VFX Deliveries v2 - <Project Name>
```

ข้อควรระวัง:

- ชื่อไฟล์ render ต้อง match กับ VFX shot code ให้ชัด
- Timeline ที่มี title/marker/clip ซ้อนซับซ้อนมากควรตรวจหลัง import
