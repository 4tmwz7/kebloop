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
| Length | `m`, meter/metre; `km`, kilometer/kilometre; `cm`, centimeter/centimetre; `mm`, millimeter/millimetre; `µm`/`um`, micrometer/micrometre/micron; `nm`, nanometer/nanometre; `mi`, mile; `yd`, yard; `ft`, foot/feet; `in`, inch/inches |
| Mass | `g`, gram; `kg`, kilogram; `mg`, milligram; `µg`/`ug`/`mcg`, microgram; `lb`/`lbs`, pound; `oz`, ounce; `st`, stone |
| Temperature | `°C`/`C`, Celsius/centigrade; `°F`/`F`, Fahrenheit; `K`, kelvin |
| Data | Bits and bytes from base through tera: `b`/`B`, `kb`/`kB`, `Mb`/`MB`, `Gb`/`GB`, `Tb`/`TB`, plus binary `Kib`/`KiB`, `Mib`/`MiB`, `Gib`/`GiB`, and `Tib`/`TiB`. Full names such as `byte`, `megabyte`, and `mebibit` are also accepted. |

Data symbols are case-sensitive: `b` means bit and `B` means byte; `MB` is a decimal megabyte, while `MiB` is a binary mebibyte. Temperature conversions include the Fahrenheit and Celsius offsets and reject values below absolute zero. Units from different dimensions cannot be converted to each other.

A comma or a period can be used as the decimal mark in conversion input. A comma is always decimal input (`1,5 km` means one and a half kilometers); grouping separators are not accepted. The displayed decimal mark follows the current locale. Existing arithmetic expressions keep their current parsing and output behavior.

## Date calculations

Use ISO dates when you want an unambiguous date. The calculator supports date differences, date addition, and the relative dates `today`, `tomorrow`, and `yesterday`:

```text
days between 2026-10-12 and 2026-10-20
date difference between 2026-10-12 and 2026-10-20
2026-10-12 to 2026-10-20
today + 10 days
2026-01-31 + 1 month
2026-03-07 12:00 + 1 day
in 3 weeks
3 days from today
```

Date addition accepts whole numbers of days, weeks, months, or years. It follows the Gregorian calendar; month addition follows Foundation calendar rules for dates near the end of a month. When a time is supplied, the local clock time is retained where the calendar permits it.

The calculator accepts `YYYY-MM-DD`, local ISO date-times such as `YYYY-MM-DD HH:mm[:ss]`, ISO-8601 timestamps with `Z` or a numeric offset, and the current locale's numeric short-date order with a four-digit year. For example, `01/02/2026` means January 2 in an `en_US` locale and February 1 in an `en_GB` locale. Use `2026-02-01` when the locale interpretation is uncertain.

Dates without an offset use the current time zone. Offset timestamps are instants; the calculator converts them to the current time zone before date arithmetic. Differences count calendar-day boundaries and can be negative. A spring daylight-saving day still counts as one calendar day even when it is 23 hours long. The current system locale and time zone control date input and displayed date format.

Currency conversion is not included because it needs a rate source, cache, and offline policy.
