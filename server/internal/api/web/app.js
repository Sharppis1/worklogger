const dateInput = document.querySelector("#date");
const timezoneInput = document.querySelector("#timezone");
const filters = document.querySelector("#filters");
const status = document.querySelector("#status");

const workTotal = document.querySelector("#work-total");
const privateTotal = document.querySelector("#private-total");
const trackedTotal = document.querySelector("#tracked-total");
const weekChart = document.querySelector("#week-chart");
const topics = document.querySelector("#topics");

const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
timezoneInput.value = timezone;
dateInput.value = localDateValue(new Date());

filters.addEventListener("submit", (event) => {
  event.preventDefault();
  loadReport();
});

function localDateValue(date) {
  const offset = date.getTimezoneOffset() * 60_000;
  return new Date(date.getTime() - offset).toISOString().slice(0, 10);
}

function dateRange(endDate, count) {
  const [year, month, day] = endDate.split("-").map(Number);
  const end = new Date(Date.UTC(year, month - 1, day, 12));
  return Array.from({length: count}, (_, index) => {
    const date = new Date(end);
    date.setUTCDate(end.getUTCDate() - (count - index - 1));
    return date.toISOString().slice(0, 10);
  });
}

async function getSummary(date, zone) {
  const query = new URLSearchParams({date, timezone: zone});
  const response = await fetch(`/v1/summaries/daily?${query}`);
  if (!response.ok) {
    const error = await response.json().catch(() => ({}));
    throw new Error(error.error || `Report request failed (${response.status})`);
  }
  return response.json();
}

async function loadReport() {
  const selectedDate = dateInput.value;
  const selectedTimezone = timezoneInput.value.trim();
  if (!selectedDate || !selectedTimezone) {
    return;
  }

  setStatus("Loading report…");
  try {
    const dates = dateRange(selectedDate, 7);
    const summaries = await Promise.all(dates.map((date) => getSummary(date, selectedTimezone)));
    const selected = summaries[summaries.length - 1];
    renderTotals(selected);
    renderWeek(summaries);
    renderTopics(selected);
    setStatus(`Updated for ${selected.date} · ${selected.timezone}`);
  } catch (error) {
    setStatus(error.message, true);
  }
}

function renderTotals(summary) {
  const tracked = summary.work_seconds + summary.private_activity_seconds + summary.idle_seconds;
  workTotal.textContent = duration(summary.work_seconds);
  privateTotal.textContent = duration(summary.private_activity_seconds);
  trackedTotal.textContent = duration(tracked);
}

function renderWeek(summaries) {
  weekChart.replaceChildren();
  const maximum = Math.max(...summaries.map((summary) => summary.work_seconds), 1);

  for (const summary of summaries) {
    const column = document.createElement("div");
    column.className = "day";

    const label = document.createElement("strong");
    label.textContent = shortDate(summary.date);

    const bar = document.createElement("progress");
    bar.max = maximum;
    bar.value = summary.work_seconds;
    bar.setAttribute("aria-label", `${summary.date}: ${duration(summary.work_seconds)} work`);

    const value = document.createElement("span");
    value.textContent = duration(summary.work_seconds);

    column.append(label, bar, value);
    weekChart.append(column);
  }
}

function renderTopics(summary) {
  topics.replaceChildren();
  const entries = Object.entries(summary.work_by_topic_seconds || {})
    .sort((a, b) => b[1] - a[1]);

  if (entries.length === 0) {
    const empty = document.createElement("p");
    empty.className = "empty";
    empty.textContent = "No work topics recorded for this day.";
    topics.append(empty);
    return;
  }

  const maximum = Math.max(...entries.map(([, seconds]) => seconds), 1);
  for (const [name, seconds] of entries) {
    const row = document.createElement("div");
    row.className = "topic";

    const label = document.createElement("strong");
    label.textContent = name || "Unspecified";

    const bar = document.createElement("progress");
    bar.max = maximum;
    bar.value = seconds;
    bar.setAttribute("aria-label", `${name}: ${duration(seconds)}`);

    const value = document.createElement("span");
    value.textContent = duration(seconds);

    row.append(label, bar, value);
    topics.append(row);
  }
}

function duration(seconds) {
  if (seconds > 0 && seconds < 60) {
    return "<1m";
  }
  const totalMinutes = Math.round(seconds / 60);
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  return `${hours}h ${String(minutes).padStart(2, "0")}m`;
}

function shortDate(value) {
  const [, month, day] = value.split("-");
  return `${day}.${month}.`;
}

function setStatus(message, isError = false) {
  status.textContent = message;
  status.classList.toggle("error", isError);
}

loadReport();
