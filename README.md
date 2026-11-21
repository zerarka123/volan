<div dir="rtl">

# volan

تطبيق جزائري لكل ما يخص السيارة: بيع وشراء بإعلانات موثّقة، طلب قطع الغيار من المحلات، حجز الميكانيكي والغسيل والكهربائي، ودباناج SOS بسعر ثابت. التواصل بين الناس يتم عبر **واتساب** فقط (لا يوجد شات داخل التطبيق) حتى يبقى التطبيق خفيفاً ورخيصاً.

## محتوى المشروع

| المجلد | ماذا فيه | التقنية |
|---|---|---|
| `supabase/` | قاعدة البيانات، قواعد الأمان، الدوال، والاختبارات | Supabase (PostgreSQL) |
| `app/` | تطبيق الهاتف (Android و iPhone) | Flutter — *قادم* |
| `admin/` | لوحة الإدارة (للمدير والفريق فقط) | Next.js — *قادم* |
| `website/` | الموقع الرسمي | Next.js — *قادم* |
| `brand/` | اللوغو وأيقونة التطبيق | SVG / PNG |
| `docs/` | الهيكلة، الخطة، والهوية البصرية | Markdown |

## تشغيل قاعدة البيانات

1. أنشئ مشروعاً مجانياً على [supabase.com](https://supabase.com).
2. ثبّت [Supabase CLI](https://supabase.com/docs/guides/cli) ثم:

```bash
supabase link --project-ref <PROJECT_REF>
supabase db push        # يطبّق ملفات supabase/migrations (فيها 69 ولاية و1541 بلدية)
```

3. عيّن أول مدير يدوياً (مرة واحدة) من محرر SQL في Supabase:

```sql
update profiles set role = 'admin' where phone = '+2136XXXXXXXX';
```

## الاختبارات

`supabase/tests/rules_test.sql` يتحقق من قواعد الأمان والمنطق (حماية رقم الهاتف، تتبع ضغطات واتساب، منع التقييمات المزيفة، حد العروض المجانية، الحظر، التوثيق…). شغّله على قاعدة **تجريبية** فقط:

```bash
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/rules_test.sql
```

النتيجة المنتظرة: `ALL TESTS PASSED` (الاختبار يلغي كل تغييراته في النهاية).

## الوثائق

- [`docs/architecture.md`](docs/architecture.md): كيف تتكلم الأجزاء مع بعضها، والجداول.
- [`docs/roadmap.md`](docs/roadmap.md): مراحل البناء.
- [`docs/brand.md`](docs/brand.md): الألوان والخطوط واللوغو.

</div>
