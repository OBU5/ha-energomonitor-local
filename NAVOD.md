# Návod: zprovoznění EnergoMonitor Homebase na jiném místě

Postup, jak celý systém rozjet znovu — s **jiným Homebase, jinou sítí a jiným Home
Assistantem**. Anglické [`HOWTO.md`](HOWTO.md) vysvětluje *proč* to funguje takhle
a rozebírá protokol; tenhle dokument je čistě *co udělat*, v pořadí.

Cílový stav: Homebase posílá měření do vaší lokální Mosquitto a **nikdy** nesáhne na
internet.

---

## Co budete potřebovat

| Věc | Poznámka |
|---|---|
| EnergoMonitor Homebase | generace **EWG6** (firmware přes HTTP, není potřeba TFTP) |
| Home Assistant OS | s doplňky (Supervisor), SSH přístup jako `root` |
| Router, na kterém umíte NAT | UniFi, OPNsense, MikroTik… musí umět DNAT **i** maskarádu |
| Přístup k routeru přes SSH | kvůli `tcpdump` v kroku 0 |
| Linuxový shell u sebe | `deploy.sh` je bash — na Windows Git Bash |

Homebase a Home Assistant musí být ve **stejné síti**. Adresy níže jsou z původní
instalace (Homebase `192.168.0.23`, HA `192.168.0.25`, router `192.168.0.1`) —
všude si dosaďte svoje.

---

## Krok 0 — Odchyt provozu. Tohle nepřeskakujte.

Bez odchytu nezískáte dvě věci, které nejdou uhodnout: **sériové číslo** a **heslo do
MQTT**. Každý Homebase má vlastní.

Na routeru jako root:

```bash
tcpdump -i any "host 192.168.0.23" -nn -A | tee /tmp/ewg_log.txt
```

Pak Homebase **vypněte a zapněte**. V odchytu hledejte:

1. **HTTP požadavek** `GET /api/device/<SN>/boot/` — v cestě je vaše 16místné
   sériové číslo (velká písmena, hex).
2. **MQTT CONNECT paket** — vypadá zhruba takhle:

   ```
   MQTT......<SN>..sn/<SN>/status..disconnected..<SN>..<HESLO>
   ```

   Podle MQTT 3.1.1 jdou položky v pevném pořadí: *client ID, will topic, will
   message, username, password* — každá s dvoubajtovou délkou. Heslo je **poslední**
   a má 16 znaků. Uživatelské jméno je totožné se sériovým číslem.

> **Heslo si nikam nezapisujte do repozitáře ani do dokumentace.** Patří jen do
> nastavení doplňku Mosquitto. Soubor s odchytem obsahuje heslo v čitelné podobě —
> po přepsání hesla do Mosquitto ho smažte, nebo aspoň uložte mimo pracovní adresář.

---

## Krok 1 — Mosquitto

Nainstalujte doplněk **Mosquitto broker**. **Před prvním spuštěním** nastavte v
Configuration dva účty:

```yaml
logins:
  - username: "<SN>"          # přesně jak to poslal Homebase, velkými písmeny
    password: "<heslo z odchytu>"
  - username: "homeassistant"
    password: "<dlouhé náhodné heslo>"
```

Dvě pasti:

- **Použijte `logins:`, ne uživatele Home Assistantu.** `logins:` zapisuje přímo do
  Mosquitto password file, takže je to bajt po bajtu přesné a rozlišuje velikost
  písmen. Autentizace přes HA jména normalizuje a Homebase posílá velká písmena.
- **Jakmile nastavíte `logins:`, přestane fungovat automatické nastavení MQTT
  integrace.** To si vygeneruje vlastní přihlášení, o kterém password file neví, a
  broker správně odpoví `not authorised`.

## Krok 2 — MQTT integrace

Nastavení → Zařízení a služby → Přidat integraci → MQTT → **"Zadat údaje o připojení
k brokeru ručně"** (ne automatické nastavení!).

| Pole | Hodnota |
|---|---|
| Broker | `core-mosquitto` |
| Port | `1883` |
| Uživatel / heslo | účet `homeassistant` z kroku 1 |

## Krok 3 — Entity a automatizace

### 3a. Vlastní sériová čísla

Soubory v repozitáři mají **zástupná** sériová čísla, aby mohl být repozitář veřejný.
Namapujte je na svoje:

```bash
cp substitutions.sed.example local/substitutions.sed
$EDITOR local/substitutions.sed
```

```sed
s/0123456789ABCDEF/<vaše SN Homebase>/g
s/01000001/<SN elektroměru>/g
s/02000002/<SN plynoměru>/g
s/08000001/<SN teploměru 1>/g
```

**První bajt sériového čísla čidla určuje typ hardwaru** — `01` elektřina, `02` plyn,
`08` teplota. Při vymýšlení nových zástupných čísel ho zachovejte.

Čísla čidel zjistíte, až Homebase začne publikovat: MQTT → Configure → Listen to a
topic → `sn/<SN>/#`, a v každé zprávě je pole `"u"`. **Napoprvé je ještě neznáte** —
projděte krok 3 znovu, až data potečou.

### 3b. Zapojení souboru entit

Do `/config/configuration.yaml` **jednou** přidejte:

```yaml
mqtt: !include mqtt.yaml
```

Bez tohohle řádku se `mqtt.yaml` nikdy nenačte, `ha core check` projde a **nevznikne
ani jedna entita** — bez jediné chybové hlášky.

### 3c. Nasazení

```bash
./deploy.sh --render      # jen vyrenderuje do build/, nic nekopíruje — zkontrolujte
./deploy.sh               # vyrenderuje, zazálohuje na Pi, nakopíruje, ha core check
```

Cíl se přepisuje proměnnými prostředí:

```bash
HA_HOST=192.168.0.25 HA_USER=root HA_KEY=~/.ssh/id_ed25519 ./deploy.sh
```

Co skript hlídá:

- **Odmítne kopírovat, když v souboru zůstane zástupné číslo.** Chybějící řádek v
  `substitutions.sed` tedy skončí chybou, ne tiše nasazenou entitou, která filtruje
  na neexistující čidlo a nikdy nic nezobrazí.
- **Automatizace *slučuje*, nepřepisuje.** Bloky EnergoMonitoru jsou v
  `/config/automations.yaml` ohraničené značkami `# >>> energomonitor …` a nahrazuje
  se jen ta část. Automatizace, které jste si vytvořili v GUI, zůstanou. (Skript umí
  převzít i instalaci nasazenou starší verzí, kde značky ještě nejsou.)

Nakonec v GUI: **Nástroje pro vývojáře → YAML → Znovu načíst automatizace** a
**Ručně nastavené entity MQTT**.

## Krok 4 — Doplněk `energo-boot`

Odpovídá na provisioning přes HTTP místo cloudu.

```bash
KEY=~/.ssh/id_ed25519
scp -i $KEY -r addon/energo-boot root@192.168.0.25:/addons/
ssh -i $KEY root@192.168.0.25 'ha store reload'
ssh -i $KEY root@192.168.0.25 'ha addons install local_energo_boot'
ssh -i $KEY root@192.168.0.25 'ha addons start   local_energo_boot'
```

> `ha store reload`, **ne** `ha addons reload`. To druhé načte jen *nainstalované*
> doplňky; nová složka v `/addons` zůstane pro store neviditelná a instalace spadne
> na `does not exist in the store`, aniž by se cokoli zalogovalo.
>
> Novější Supervisor hlásí u `ha addons` upozornění „use 'apps' instead" — příkazy
> pořád fungují, případně použijte `ha apps …`.

Pak v GUI doplňku (Configuration):

| Volba | Hodnota |
|---|---|
| `device_sn` | vaše 16místné SN |
| `mqtt_host` | IP Home Assistantu, např. `192.168.0.25` |
| `mqtt_port` | `1883` |
| `broadcast` | `0` |
| `crlf` / `trailing_newline` | `true` / `false` — neměňte, dokud to funguje |

A na kartě Info zapněte **Watchdog**.

> **Neběží-li HA na ARM64:** v `addon/energo-boot/config.yaml` je `arch: [aarch64]`.
> Na Intelu/AMD doplňte `amd64`, jinak se doplněk vůbec nenainstaluje.

Doplněk **nemá zástupná čísla** — SN si bere z nastavení (`/data/options.json`),
takže se nerenderuje přes `deploy.sh` a kopíruje se tak, jak je.

## Krok 5 — NAT na routeru: DNAT **a** SNAT

Homebase má IP `46.137.108.21` **napevno v kódu** a **nedělá žádný DNS dotaz** — v
odchytu není ani jeden a hlavička požadavku je `Host: 46.137.108.21`, tedy holá IP.
**Přesměrování přes DNS proto nemůže fungovat.** Jediná cesta je NAT na routeru.

Na UniFi Network 9.x: Settings → Policy Table → Create New Policy → **NAT**.

| | Pravidlo 1 | Pravidlo 2 |
|---|---|---|
| Typ | **Dest. NAT** | **Masquerade** |
| Interface | Default (`192.168.0.0/24`) | Default (`192.168.0.0/24`) |
| Protokol | TCP | TCP |
| Zdroj | IP `192.168.0.23`, port **Any** | IP `192.168.0.23`, port **Any** |
| Cíl | IP `46.137.108.21`, port `80` | IP `192.168.0.25`, port `80` |
| Translated | `192.168.0.25` | — |

Obě pravidla pak **přesuňte nad** výchozí `Translate Network …` maskarádová pravidla.

**Druhé pravidlo není volitelné.** Homebase (`.23`) a HA (`.25`) jsou ve stejné
`/24` síti. Se samotným DNAT odpoví Pi přímo na `.23` po druhé vrstvě, se zdrojovou
adresou `192.168.0.25`, a nikdy se nevrátí přes router, kde by se překlad zrušil.
Homebase čeká na odpověď od `46.137.108.21`, dostane paket od cizí adresy a spojení
shodí (RST). **Pravidlo 1 přitom vypadá naprosto v pořádku.**

**Nefixujte zdrojový port.** Zařízení používá pokaždé jiný efemérní port (`49451`,
`49356`, `49165`, …); pravidlo přibité na jeden port nesedne nikdy — a mlčky.

Pokud si nejste jistí, že to GUI dělá, co si myslíte, ověřte si to napřed přes
`iptables` (dočasné, po restartu zmizí):

```bash
iptables -t nat -A PREROUTING  -i br0 -p tcp -d 46.137.108.21 --dport 80 -j DNAT --to-destination 192.168.0.25:80
iptables -t nat -A POSTROUTING -o br0 -p tcp -d 192.168.0.25  --dport 80 -j MASQUERADE
```

## Krok 6 — Restart Homebase

**Až teď** Homebase vypněte a zapněte.

---

## Pořadí kroků není libovolné

Když něco ještě neposlouchá ve chvíli, kdy se Homebase ptá, promešká se celý cyklus
a čeká se na další pokus. Správné pořadí:

1. Mosquitto běží, oba účty nastavené
2. MQTT integrace připojená (ručně, ne automaticky)
3. Automatizace načtené
4. Doplněk `energo-boot` nainstalovaný a odpovídá na `:80`
5. NAT pravidla na routeru
6. **Teprve pak** restart Homebase

---

## Ověření

```bash
curl -i --http1.0 http://192.168.0.25/api/device/<SN>/boot/
#   200, Content-Length: 54, tělo oddělené CRLF

curl -i --http1.0 http://192.168.0.25/api/device/<SN>/upgrade/
#   404, Content-Length: 0
```

Na Windows použijte `curl.exe` — samotné `curl` je v PowerShellu alias na
`Invoke-WebRequest`, které má jiné přepínače a nad 404 vyhodí výjimku.

| Kontrola | Očekávaný výsledek |
|---|---|
| Log doplňku při restartu Homebase | požadavky z `192.168.0.1` (to je ta maskaráda) nebo z `.23` |
| Log Mosquitto | `New client connected … as <SN>` |
| MQTT → Listen to topic `sn/<SN>/#` | `status=connected`, pak `clock/init`, `collector/init`, pak `data` |
| Odpojení napájení Homebase | entity přejdou na `unavailable` (last-will zpráva) |

A kontrola, která dokazuje vlastní cíl — na routeru:

```bash
tcpdump -i any host 192.168.0.23 and not net 192.168.0.0/24
```

**Ticho = Homebase už s internetem nemluví.**

---

## Když to nejede

| Příznak | Příčina |
|---|---|
| V logu doplňku nejsou **žádné** požadavky | nesedí pravidlo 1 (DNAT) |
| Požadavky chodí, ale Homebase to pořád zkouší dokola | chybí pravidlo 2 (maskaráda) |
| Mosquitto hlásí `not authorised` | jméno/heslo nesedí bajtově — pozor na velikost písmen |
| Homebase se připojí, ale **nic neposílá** | nenačetly se automatizace; Homebase nepošle ani jedno měření, dokud nedostane odpověď na `clock/init` **i** `collector/init` |
| Nevznikly žádné entity | chybí `mqtt: !include mqtt.yaml` v `configuration.yaml` |
| `ha addons install` hlásí `does not exist in the store` | zapomenutý `ha store reload` |
| Entity se jmenují `..._energomonitor_electricity_energy` | `name:` obsahuje i jméno zařízení; HA ho od verze 2023.8 předřazuje sám. `entity_id` se přiděluje jen jednou — pozdější oprava jména ho nepřejmenuje |

---

## Přidání dalšího čidla

Nové čidlo se v MQTT objeví samo, ale **entita z něj sama nevznikne** — seznam entit
je vypsaný ručně.

1. Zjistěte jeho sériové číslo: MQTT → Configure → Listen to a topic → `sn/<SN>/#`
   a hledejte neznámé `"u"`. Kódy `"m"` prozradí, co měří.
2. Zkopírujte existující blok v `ha-config/mqtt.yaml`, změňte filtr na `u` na
   **nové zástupné číslo** (zachovejte první bajt podle typu) a upravte kód `m`.
3. Přidejte řádek do `local/substitutions.sed`.
4. `./deploy.sh` a znovu načtěte entity MQTT.

**Nikdy nefiltrujte podle `ch` (kanálu).** Kanály jsou jen pozice, které Homebase
při rekonfiguraci přehází — 28. 8. 2026 si elektroměr a plynoměr prohodily kanál 0 a
1. Sériová čísla jsou stálá. Filtrování podle kanálu by tiše přesměrovalo hodnoty
plynu do entity elektřiny: žádná chyba, jen dva grafy, které lžou.

### Kódy médií (`m`)

| Kód | Význam | Jednotka |
|---|---|---|
| 10 | LQI, kvalita spoje | — |
| 11 | RSSI, síla signálu | dBm |
| 12 | okamžitý elektrický výkon | W |
| 13 | průtok plynu | L/h |
| 15 | počet pulzů | — |
| 16 | teplota | °C |
| 25 | IPU, pulzů na jednotku | #/kWh, #/m³ |

Energie `kWh = m15 / m25`, objem plynu `m³ = m15 / m25`.

**Údaj o baterii neexistuje.** Optosense posílá `15/25/12/11`, Relaysense Gas
`15/25/13/11`, Thermosense `16/11`. Žádné z nich baterii nehlásí.

---

## Bezpečnost

- Heslo Homebase do MQTT **nejde změnit** a po síti chodí v čitelné podobě při každém
  připojení. Za zvážení stojí ACL, které tomu účtu povolí jen `sn/<SN>/#` — jinak by
  mohl publikovat do `homeassistant/sensor/.../config` a vytvářet libovolné entity.
  Nejdřív si přečtěte `mosquitto.conf` dodaný s doplňkem: globální `acl_file`, který
  nedá plný přístup i Home Assistantu, rozbije jeho vlastní připojení.
- Do repozitáře **nikdy** nepatří skutečné sériové číslo ani heslo. Skutečná identita
  žije jen v `local/substitutions.sed` (gitignorovaný) a heslo jen v nastavení
  doplňku Mosquitto.
