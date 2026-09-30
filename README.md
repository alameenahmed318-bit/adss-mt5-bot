# ADSS MT5 EA

نسخة EA تعمل داخل MetaTrader 5 مباشرة، بدون Python.

## الوظائف
- فحص السوق وحماية الصفقات كل 2 ثانية.
- EURUSD, GBPUSD, USDJPY, AUDUSD, USDCHF, USDCAD, NZDUSD, EURJPY, GBPJPY, XAUUSD.
- EMA + RSI + اتجاه الشمعة كإشارة بسيطة ومتكيّفة مع السوق.
- وقف أولي مبني على ATR.
- حجم الصفقة محسوب حسب نسبة المخاطرة.
- حماية ربح ديناميكية تبدأ بعد 0.6R، تقفل جزءاً من الربح عند 0.10R، ثم تستخدم ATR trailing.
- عزل صارم باستخدام Magic Number 826001: الـEA لا يقرأ أو يعدل أو يغلق صفقات يدوية أو صفقات EA أخرى.
- لا يوجد حد خسارة يومي داخل هذه النسخة.
- DEMO_ONLY=true افتراضياً.

## التشغيل
1. افتح MetaTrader 5 على Windows وسجّل الدخول إلى حساب ADSS Demo.
2. افتح MetaEditor من MT5.
3. File -> Open Data Folder -> MQL5 -> Experts.
4. انسخ ملف ADSS_MT5_EA.mq5 إلى مجلد Experts.
5. افتح الملف في MetaEditor واضغط Compile.
6. ارجع إلى MT5، فعّل Algo Trading، وافتح أي Chart.
7. اسحب ADSS_MT5_EA إلى الـChart.
8. اترك InpDemoOnly=true أولاً وراقب Experts وJournal.

الـEA يحاول مطابقة أسماء رموز ADSS تلقائياً، بما في ذلك بعض suffixes/prefixes.

هذه نسخة بداية تقنية وليست ضماناً للربحية. اختبرها على Demo قبل Live.
