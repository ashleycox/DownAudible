"""Keep purchase filters as calendar dates and send local day boundaries to Audible."""

from datetime import date, datetime, time, timedelta, timezone


def parse_purchase_date(value):
    text = value.strip()
    if not text:
        return ""
    try:
        day = date.fromisoformat(text)
    except ValueError:
        day = None
    if day is None or day.isoformat() != text:
        raise ValueError("Enter purchase dates as YYYY-MM-DD.")
    return text


def purchase_date_text(value):
    if isinstance(value, (int, float)):
        # Previous profiles encoded the selected calendar dates as UTC timestamps.
        try:
            return datetime.fromtimestamp(value, timezone.utc).date().isoformat()
        except (ValueError, OverflowError, OSError):
            pass
    return str(value) if value is not None else ""


def purchase_date_options(api):
    options = dict(api)
    start = parse_purchase_date(purchase_date_text(options.pop("purchaseStart", "")))
    end = parse_purchase_date(purchase_date_text(options.pop("purchaseEnd", "")))
    if start and end and start > end:
        raise ValueError("Choose a purchase end date on or after the start date in Settings > Library.")
    try:
        if start:
            options["purchaseStart"] = datetime.combine(date.fromisoformat(start), time.min).timestamp()
        if end:
            next_day = date.fromisoformat(end) + timedelta(days=1)
            options["purchaseEnd"] = datetime.combine(next_day, time.min).timestamp() - 0.000001
    except (ValueError, OverflowError, OSError):
        raise ValueError("Choose purchase dates within the supported calendar range.") from None
    return options
