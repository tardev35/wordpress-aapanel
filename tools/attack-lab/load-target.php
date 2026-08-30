<?php
// load-target.php — เป้าจำลองที่ "รัน PHP จริง" สำหรับดูภาระ CPU บนเครื่องตัวเอง
//
// รันด้วย PHP built-in server:
//     php -S 127.0.0.1:8099 tools/attack-lab/load-target.php
//
// แล้วยิงด้วย hammer.py อีกหน้าต่าง — ดู CPU ของ php.exe ใน Task Manager
//
// ทุก request ทำงาน CPU จริง ~35ms เท่าเว็บ WordPress ทั่วไป 1 หน้า
// มีเพดานเวลา จบเองเสมอ ไม่ใช่ลูปไม่รู้จบ

$t = microtime(true);
$x = 0.0;
while (microtime(true) - $t < 0.035) {      // ทำงาน 35ms แล้วหยุด
    $x += sqrt(mt_rand(1, 1000000)) * sin($x + 1.234);
}
header('Content-Type: text/plain');
header('X-Load-Demo: 1');   // เครื่องหมายว่าเป็น endpoint ซ้อมโหลดที่เราตั้งเอง
echo "ok ", number_format($x, 2);
