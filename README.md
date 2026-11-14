# Bangkok MPC — Membership

ระบบสมาชิกชมรมปัญจกีฬากรุงเทพมหานคร (Bangkok Modern Pentathlon Club)

- `index.html` — เว็บทั้งหมดในไฟล์เดียว (static, ไม่ต้อง build) deploy ได้ทันทีบน Netlify / Vercel / GitHub Pages
- `supabase/schema.sql` — สำเนา schema ของฐานข้อมูล (เพื่ออ้างอิง ไม่ต้องรันซ้ำบนโปรเจคจริง)

## Stack
- Supabase project **Bangkok MPC** (ref `yrzwbcqargyatagcgiuy`, ap-southeast-1)
- supabase-js + Chart.js (CDN)
- Auth: สมัครด้วย OTP อีเมล → ตั้งรหัสผ่าน → ล็อกอินด้วยอีเมล + รหัสผ่าน

## Roles
- `student` = สมาชิก (ค่าเริ่มต้นตอนสมัคร) — ดูข้อมูลและสถิติของตัวเอง, ดูอันดับชมรม
- `coach` — จัดการสมาชิก, สร้างกิจกรรมและเช็คชื่อ, บันทึกผลแข่ง

ตั้งโค้ชคนแรกด้วย SQL (หลังสมัครผ่านเว็บแล้ว):

```sql
update public.profiles set role = 'coach'
where id = (select id from auth.users where email = '<อีเมล>');
```

## รุ่น (Age group)
คำนวณตามกติกา UIPM: อายุ = ปีที่แข่ง − ปีเกิด (ไม่นับเดือนและวัน)
U9 ≤8 · U11 9–10 · U13 11–12 · U15 13–14 · U17 15–16 · U19 17–18 · Junior 19–21 · Senior 22+

## CI
Navy `#0A2549` · Red `#B80606` · Gold `#B8760F` / `#D4943A`
