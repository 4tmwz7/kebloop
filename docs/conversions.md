# Calculator conversions and date calculations

The launcher evaluates conversions and date calculations inline. Select the result and press Return to copy it. Conversion and date results include their unit or date in the copied text.

## Unit conversions

Write a number, a unit, and `to`, `in`, or `as` followed by the destination unit:

```text
12 km to mi
5 kilograms in pounds
32 °F to °C
1 MB as MiB
```

Unit names are case-insensitive except for data-unit symbols. You can use singular or plural names for the listed units.

| Dimension | Supported units and common aliases |
| --- | --- |
| Length | `m`, meter/metre; `km`, kilometer/kilometre; `cm`, centimeter/centimetre; `mm`, millimeter/millimetre; `µm`/`um`, micrometer/micrometre/micron; `nm`, nanometer/nanometre; `mi`, mile; `yd`, yard; `ft`, foot/feet; `in`, inch/inches (`inchs` is also accepted) |
| Mass | `g`, gram; `kg`, kilogram; `mg`, milligram; `µg`/`ug`/`mcg`, microgram; `lb`/`lbs`, pound; `oz`, ounce; `st`, stone |
| Temperature | `°C`/`C`, Celsius/centigrade; `°F`/`F`, Fahrenheit; `K`, kelvin |
| Data | Bits and bytes from base through tera: `b`/`B`, `kb`/`kB`, `Mb`/`MB`, `Gb`/`GB`, `Tb`/`TB`, plus binary `Kib`/`KiB`, `Mib`/`MiB`, `Gib`/`GiB`, and `Tib`/`TiB`. Full names such as `byte`, `megabyte`, and `mebibit` are also accepted. |
| Duration | `ms`, `s`/`sec`, `min`, `h`/`hr`, `d`, and `wk`, with singular and plural names. A day is 24 hours and a week is 7 days. |

Data symbols are case-sensitive: `b` means bit and `B` means byte; `MB` is a decimal megabyte, while `MiB` is a binary mebibyte. Temperature conversions include the Fahrenheit and Celsius offsets and reject values below absolute zero. Units from different dimensions cannot be converted to each other.

Durations can be converted with the same syntax, for example `90 minutes to hours` or `2 weeks in seconds`. You can add or subtract quantities that use different units from the same dimension; the result uses the first unit:

```text
2 km + 300 m
1 hour + 30 minutes
3 ft - 4 in
```

Mixed-unit arithmetic supports addition and subtraction. It does not combine absolute temperatures.

A comma or a period can be used as the decimal mark in conversion input. A comma is always decimal input (`1,5 km` means one and a half kilometers); grouping separators are not accepted. The displayed decimal mark follows the current locale. Existing arithmetic expressions keep their current parsing and output behavior.

## Date calculations

Use ISO dates when you want an unambiguous date. The calculator supports date differences, date addition, and the relative values `now`, `today`, `tomorrow`, and `yesterday`. Typing `today` alone shows the local date; `now` alone shows the local date and time:

```text
today
now
now + 1 day
days between 2026-10-12 and 2026-10-20
date difference between 2026-10-12 and 2026-10-20
2026-10-12 to 2026-10-20
today + 10 days
2026-01-31 + 1 month
2026-03-07 12:00 + 1 day
in 3 weeks
3 days from today
```

Date addition accepts whole numbers of days, weeks, months, or years. Results must fall within Gregorian years 1–9999; overflowing numbers and offsets outside that range report an error instead of returning today. It follows the Gregorian calendar; month addition follows Foundation calendar rules for dates near the end of a month. When a time is supplied, the local clock time is retained where the calendar permits it.

The calculator accepts `YYYY-MM-DD`, local ISO date-times such as `YYYY-MM-DD HH:mm[:ss]`, ISO-8601 timestamps with `Z` or a numeric offset, and the current locale's numeric short-date order with a four-digit year. For example, `01/02/2026` means January 2 in an `en_US` locale and February 1 in an `en_GB` locale. Use `2026-02-01` when the locale interpretation is uncertain.

Dates without an offset use the current time zone. Offset timestamps are instants; the calculator converts them to the current time zone before date arithmetic. Differences count calendar-day boundaries and can be negative. A spring daylight-saving day still counts as one calendar day even when it is 23 hours long. The current system locale and time zone control date input and displayed date format.

## Time zones

Show the current time in a named zone, or convert a clock time between named zones:

```text
time in Tokyo
9:30 AM in New York to London
17:00 Warsaw to Tokyo
9 AM PST to CET
```

Time-only conversions use the current date in the source zone so daylight-saving rules are applied for that date. The result includes the destination date, local time, zone name, and GMT offset. Common city names and abbreviations are recognized, including New York, Los Angeles, London, Warsaw, Tokyo, and Sydney; an IANA identifier such as `America/New_York` also works.

## Currency conversions

Currency queries use the same `to`, `in`, or `as` syntax:

```text
100 USD to EUR
$50 in PLN
€20 to dollars
100 yen to USD
```

ISO currency codes are supported for USD, EUR, GBP, JPY, CNY, CAD, AUD, NZD, CHF, PLN, SEK, NOK, DKK, CZK, HUF, RON, BGN, TRY, INR, SGD, HKD, KRW, MXN, BRL, ZAR, RUB, THB, IDR, MYR, PHP, ILS, AED, SAR, TWD, ISK, UAH, and VND. Common currency names and symbols are accepted; `$` means USD, `€` means EUR, and `£` means GBP. Use an ISO code when a symbol could refer to more than one currency.

Rates come from [Frankfurter](https://frankfurter.dev/), which publishes daily mid-market reference rates. Kebloop requests only the currency pair in the query, caches at most 64 pairs, refreshes a cached pair after 24 hours, and retains observations for up to 30 days for offline use. Every conversion shows the provider's rate date; a stale saved rate is marked `cached`. The displayed note is not included when you copy the converted amount. If no saved rate exists and the request cannot complete, the calculator reports that a connection is needed. Rate lookup runs asynchronously and does not wait in the typing path.
