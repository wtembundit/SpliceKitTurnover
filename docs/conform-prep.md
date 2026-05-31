# Conform Prep Guide

`Conform Prep` เป็นเครื่องมือสำหรับแปลง timeline ที่มี `sync-clip` ให้กลายเป็น timeline ที่อ้างอิง original source clip มากขึ้น เพื่อให้ VFX/online conform อ่าน source file, source timecode และ retime ได้ใกล้กับสิ่งที่เห็นใน Final Cut Pro

## 🎯 เป้าหมาย

- ลด `sync-clip` ที่ซ้อนอยู่ใน timeline ให้กลายเป็น source-backed clip
- Preserve visible frame แรกและเฟรมสุดท้ายให้ตรงกับ timeline ต้นฉบับ
- Preserve speed segment, speed ramp/transition, reverse และ blade speed ให้มากที่สุด
- Preserve title, marker, transform, role และ metadata ที่ติดกับคลิป
- ทำให้ FCP import XML กลับมาได้โดยไม่เกิดคลิปหายหรือ warning เท่าที่เป็นไปได้

## 🧠 หลักคิดของการคำนวณ speed

เวลาที่ editor ทำงาน manual มักเป็นสองชั้น:

1. Break apart หรือ flatten sync clip เพื่อให้เห็น original source clip ด้านใน
2. คูณ speed ของชั้นนอกเข้ากับ speed ของ original clip ด้านใน แล้วปรับ blade/speed segment ให้ visible source timecode ตรงกับ timeline ต้นฉบับ

Conform Prep ใช้แนวคิดเดียวกัน:

```text
effective speed = inner source speed × outer sync clip speed
```

ตัวอย่าง:

```text
inner clip = 200%
sync clip = 130%
flattened source clip = 260%
```

ถ้าเป็น reverse:

```text
inner clip = 200%
sync clip = -115%
flattened source clip = -230%
```

## ⚡ Speed Segment และ Speed Ramp

Final Cut Pro ไม่ได้เก็บ retime เป็นแค่ค่า speed เดียวเสมอไป บางคลิปมี:

- constant speed
- blade speed หลายช่วง
- speed transition/ramp ที่ค่อยๆ เปลี่ยนความเร็ว
- reverse segment
- timeMap ที่ใช้ interpolation เช่น `smooth2`

Conform Prep จึงพยายามอ่าน timeMap ทั้งชั้นนอกและชั้นใน แล้วสร้าง flattened timeMap ใหม่ที่รักษา:

- visible source TC in/out
- จุดเปลี่ยน speed สำคัญ
- ค่าความเร็วที่เป็นผลคูณจริง
- จำนวน segment ที่ใกล้กับต้นฉบับ ไม่สร้าง blade ชดเชยเกินจำเป็น

## 🧩 Checkpoint คืออะไร

ระหว่างพัฒนาเราใช้ checkpoint จาก source timecode window ใน Final Cut Pro เพื่อตรวจว่าจุดต่างๆ ตรงหรือไม่ แต่ใน workflow จริง user ไม่ต้องป้อน checkpoint เอง

Script จะ derive จุดอ้างอิงจาก FCPXML:

- timeMap ของ sync clip ชั้นนอก
- timeMap ของ original clip ด้านใน
- source start ของ asset
- offset/start/duration ของ clip
- visible source time ที่คำนวณหลัง flatten

สิ่งสำคัญคือ checkpoint ต้องอิง original source clip ด้านใน ไม่ใช่ sync clip timecode เพราะ sync clip timecode อาจถูกสร้างมาไม่ตรงกับ source จริง

## 🏷 Title, Marker, Transform และ Metadata

Conform Prep พยายามย้าย connected element ที่เกี่ยวข้องตาม timeline position จริง ไม่ใช่ยึดแค่ parent clip เดิมเสมอไป เพราะใน FCP title อาจ:

- เริ่มก่อนคลิปไม่กี่เฟรมแต่พาดยาวข้ามคลิปถัดไป
- ยาวกว่าคลิปที่มัน connected อยู่
- สั้นกว่าคลิปหลัก
- ซ้อนกับ title อื่นจนดูเหมือนหาย

กฎปัจจุบันพยายาม preserve โดยดู timeline range และ connection point ร่วมกัน แต่ยังเป็นจุดที่ต้องเก็บเคสเพิ่มต่อ

## ✅ เคสที่รองรับดีขึ้นแล้ว

- Simple sync clip flatten
- Sync clip ที่ speed ชั้นนอกอย่างเดียว
- Original clip ด้านในมี speed แล้ว sync clip ด้านนอกมี speed ซ้อน
- Constant retime ที่ต้องจับ TC in/out ให้ตรง
- Blade speed หลายช่วงในตัวอย่างทดสอบ
- Reverse retime ในตัวอย่างทดสอบ
- Title/marker/transform/metadata หลายรูปแบบใน timeline จริง

## ⚠️ Known Limitations

ยังมีเคสที่ต้องตรวจหลัง import:

- Multicam ยังไม่ใช่เป้าหมายหลัก เพราะมีเครื่องมือเฉพาะอย่าง Multicam Flattener ที่เหมาะกว่า
- Retime pattern ที่ซับซ้อนมากและไม่เคยเจออาจ drift 1-2 frames หรือมากกว่า
- Speed ramp บางแบบใน FCPXML อาจแสดงผลไม่ตรง 100% กับ UI ของ FCP เพราะ FCP มีการปัดเศษค่า speed
- Title ที่พาดข้ามหลาย clip หรือมี connection point แปลกยังอาจหาย/ซ้อน/ยาวไม่เท่าต้นฉบับในบางกรณี
- Marker ที่เกิดจาก structure เดิมบางแบบอาจต้องลบหรือ normalize เพิ่ม

## 🧪 วิธี report เคสที่พลาด

ถ้าเจอเคสที่ import แล้วไม่ตรง ให้เก็บ:

- original `.fcpxmld` หรือ `.fcpxml`
- output `.fcpxmld` หลัง run
- screenshot before/after
- ชื่อ clip ที่ผิด
- expected source TC in/out ถ้ามี
- ระบุว่า speed เป็น constant, blade speed, ramp หรือ reverse

ข้อมูลพวกนี้ช่วยให้เราทำกฎ generic ต่อได้โดยไม่ hardcode เฉพาะ shot
