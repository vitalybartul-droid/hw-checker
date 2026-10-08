Флешка приёмки б/у ПК — Debian Live + hwcheck (проверено на Debian Live 13.7.0, HP EliteBook 850 G7)

1. Скачать debian-live-13.x.x-amd64-standard.iso
   (cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/, вариант standard, НЕ gnome).
2. Записать Rufus: MBR, BIOS or UEFI, FAT32, при вопросе выбрать «ISO-образ».
3. Скопировать в корень флешки папки hwcheck и live из этого архива
   (папка live на флешке уже есть — в неё добавится config-hooks).
4. В файле boot/grub/grub.cfg на флешке:
   - сразу после строки «source /boot/grub/config.cfg» добавить:
         set default=0
         set timeout=1
   - в первом пункте «Live system (amd64)», в конец строки linux дописать через пробел:
         hooks=file:///run/live/medium/live/config-hooks/9990-hwcheck
     (именно так, а не hooks=medium: в Debian 13 вариант medium ищет хуки
      по старому пути /lib/live/mount/medium и ничего не находит).
   Для 13.7.0 готовый grub.cfg лежит в этом архиве — можно просто заменить.
   Для другой версии образа править вручную: в файле прописана версия ядра.
5. Редактировать только в Notepad++ (переводы строк LF).

Пакеты .deb для Debian 13 (trixie, amd64) из hwcheck/debs/ ставятся при загрузке.
Для теста памяти (M) нужен memtester: packages.debian.org/trixie/memtester -> amd64 -> скачать .deb.

Работа: флешка → F9 (HP) / F12 (Lenovo, Dell) → USB → ~1 мин → отчёт.
После отчёта меню: Enter = выключить, K = клавиатура, C = зарядка (живой монитор),
V = экран (битые пиксели), D = диски, M = память, L = листать отчёт, S = консоль. Отчёт и результаты тестов в /tmp/hwcheck.txt.
В строке linux grub.cfg стоит memtest=1 — быстрый тест памяти ядром при загрузке (+несколько секунд).
