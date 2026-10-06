const hasРоднойBridge = Boolean(window.webkit?.messageHandlers?.generalsX);
const nativePending = new Map();
let nativeRequestCounter = 0;
let nativeState = null;
let nativeДиагностикаText = "";
const homeСкачатьState = new Map();
const downloadMetrics = new Map();

window.GeneralsXРодной = {
  request(action, payload = {}, timeoutMs = 20000) {
    if (!hasРоднойBridge) return Promise.reject(new Error("Родной bridge is unavailable"));
    const id = `gx-${Date.now()}-${++nativeRequestCounter}`;
    return new Promise((resolve, reject) => {
      const timer = window.setTimeout(() => {
        nativePending.delete(id);
        reject(new Error(`Родной action timed out: ${action}`));
      }, timeoutMs);
      nativePending.set(id, {
        resolve(value) { window.clearTimeout(timer); resolve(value); },
        reject(error) { window.clearTimeout(timer); reject(error); }
      });
      try {
        window.webkit.messageHandlers.generalsX.postMessage({ id, action, payload });
      } catch (error) {
        window.clearTimeout(timer);
        nativePending.delete(id);
        reject(error);
      }
    });
  },

  _receive(envelope) {
    if (!envelope || typeof envelope !== "object") return;

    if (envelope.type === "response") {
      const pending = nativePending.get(envelope.id);
      if (!pending) return;
      nativePending.delete(envelope.id);
      if (envelope.ok) pending.resolve(envelope.result);
      else pending.reject(new Error(envelope.error || "Родной request failed"));
      return;
    }

    if (envelope.type === "event") {
      handleРоднойEvent(envelope.name, envelope.payload || {});
    }
  }
};

function nativeRequest(action, payload = {}) {
  return window.GeneralsXРодной.request(action, payload);
}

function nativeProfileIdForCard(card = activeCard) {
  const id = card?.dataset?.id || "zero-hour-online";
  if (id === "zero-hour-online") return "online";
  return id;
}

function nativeModState(modId) {
  return nativeState?.mods?.find(item => item.profileId === modId) || null;
}

function nativeProfileState(profileId) {
  if (profileId === "online") return nativeState?.online || null;
  return nativeModState(profileId);
}

function applyРоднойState(state) {
  if (!state || typeof state !== "object") return;
  nativeState = state;

  installedMods = (state.mods || [])
    .filter(item => item.installed)
    .map(item => item.profileId);

  (state.mods || []).forEach(item => {
    const mod = modCatalog.find(candidate => candidate.id === item.profileId);
    if (!mod) return;
    mod.title = item.name || mod.title;
    mod.description = item.description || mod.description;
    mod.version = item.version || "";
    mod.installedВерсия = item.installedВерсия || "";
    mod.updateAvailable = Boolean(item.updateAvailable);
    mod.packageBytes = Number(item.packageBytes || 0);
    mod.releaseNotes = item.releaseNotes || "";
    mod.channel = item.channel || state.channel || "stable";
    mod.requestedChannel = item.requestedChannel || state.channel || "stable";
    mod.fallbackChannel = item.fallbackChannel || "";
    if (item.sourceURL) mod.moddbUrl = item.sourceURL;
    if (item.author) mod.author = item.author;
  });

  if (state.download?.busy && state.download.profileId) {
    const profileId = state.download.profileId;
    downloadMetrics.set(profileId, {
      ...downloadMetrics.get(profileId),
      ...state.download
    });
    setHomeСкачатьProgress(profileId, Number(state.download.fraction || 0), true);
  }

  syncУстановитьedModCards();
  syncActiveModSourceLink();
  syncРоднойSystemСтатус();

  if (!modalBackdrop.hidden && modalTitle.textContent === "Добавить мод") {
    renderModLibrary();
  }
}

function syncРоднойSystemСтатус() {
  if (!nativeState) return;
  const engine = document.querySelector("#systemEngine");
  const launcher = document.querySelector("#systemLauncher");
  const gameData = document.querySelector("#systemФайлы игры");
  const profiles = document.querySelector("#systemProfiles");
  const footerBuild = document.querySelector("#footerBuild");

  if (engine) engine.textContent = nativeState.engineВерсия || "unknown";
  if (launcher) launcher.textContent =
    `${nativeState.launcherВерсия || "unknown"} · web ${nativeState.launcherWebВерсия || "bundled"}`;
  const onlineУстановитьed = Boolean(nativeState.online?.installed);
  if (gameData) {
    gameData.textContent = onlineУстановитьed ? "Готово" : "Не установлено";
    gameData.classList.toggle("good", onlineУстановитьed);
  }
  if (profiles) {
    const installedCount = (onlineУстановитьed ? 1 : 0) + (nativeState.mods || []).filter(item => item.installed).length;
    profiles.textContent = `${installedCount} готово`;
  }
  if (footerBuild) footerBuild.textContent = `BUILD ${nativeState.build || "unknown"}`;

  const currentProfileId = nativeProfileIdForCard();
  const profile = nativeProfileState(currentProfileId);
  const installed = Boolean(profile?.installed);
  const updateAvailable = Boolean(profile?.updateAvailable);
  statusLabel.textContent = installed ? (updateAvailable ? "ОБНОВИТЬ" : "ГОТОВО") : "NOT УСТАНОВИТЬED";
  statusLabel.classList.toggle("status-text--warning", !installed || updateAvailable);
  statusLabel.classList.toggle("status-text--готово", installed && !updateAvailable);
  playLabel.textContent = !installed ? "УСТАНОВИТЬ" : (updateAvailable ? "ОБНОВИТЬ" : "ИГРАТЬ");
}

async function syncРоднойState() {
  if (!hasРоднойBridge) return;
  try {
    applyРоднойState(await nativeRequest("getState"));
  } catch (error) {
    showToast(error.message || "Не удалось прочитать состояние лаунчера");
  }
}

function updateРоднойProgress(payload) {
  const profileId = payload.profileId;
  if (!profileId) return;
  const metrics = {
    ...downloadMetrics.get(profileId),
    ...payload,
    busy: true
  };
  downloadMetrics.set(profileId, metrics);
  setHomeСкачатьProgress(profileId, Number(metrics.fraction || 0), true);
  updateСкачатьPanel(profileId);
}

function handleРоднойEvent(name, payload) {
  if (name === "stateChanged") {
    applyРоднойState(payload);
    return;
  }
  if (name === "downloadProgress") {
    updateРоднойProgress(payload);
    return;
  }
  if (name === "installComplete") {
    const title = modCatalog.find(item => item.id === payload.profileId)?.title ||
      (payload.profileId === "online" ? "Zero Hour + Online" : payload.profileId);
    downloadMetrics.delete(payload.profileId);
    finishHomeСкачать(payload.profileId, "complete");
    triggerHaptic("success");
    showToast(`${title} installed`);
    syncРоднойState().then(() => {
      const installedCard = cardForProfileId(payload.profileId);
      if (installedCard) setActiveCard(installedCard);
    });
    return;
  }
  if (name === "downloadОтменаled") {
    downloadMetrics.delete(payload.profileId);
    finishHomeСкачать(payload.profileId, "cancel");
    showToast("Загрузка отменена");
    syncРоднойState();
    return;
  }
  if (name === "installError") {
    downloadMetrics.delete(payload.profileId);
    finishHomeСкачать(payload.profileId, "error");
    showToast(payload.error || "Ошибка установки");
    syncРоднойState();
  }
}

const cards = [...document.querySelectorAll(".mode-card")];
const hero = document.querySelector(".hero");
const modeTitle = document.querySelector("#modeTitle");
const modeОписание = document.querySelector("#modeОписание");
const profileLabel = document.querySelector("#profileLabel");
const statusLabel = document.querySelector("#statusLabel");
const playLabel = document.querySelector("#playLabel");
const playButton = document.querySelector("#playButton");
const detailsButton = document.querySelector("#detailsButton");
const toast = document.querySelector("#toast");
const modalBackdrop = document.querySelector("#modalBackdrop");
const modalClose = document.querySelector("#modalClose");
const modalTitle = document.querySelector("#modalTitle");
const modalEyebrow = document.querySelector("#modalEyebrow");
const modalBody = document.querySelector("#modalBody");
const modalHeaderActions = document.querySelector("#modalHeaderActions");
const modSourceLink = document.querySelector("#modSourceLink");
const modesRail = document.querySelector(".modes");
const addModCard = document.querySelector(".add-mod-card");
const audioToggle = document.querySelector("#audioToggle");
const launcherEsc = document.querySelector("#launcherEsc");


const backgroundPrimary = document.querySelector(".battlefield__tile--primary");
const backgroundSecondary = document.querySelector(".battlefield__tile--secondary");
const backgroundGrid = document.querySelector(".battlefield__grid");

const backgroundSlides = [
  "./assets/bg1.png",
  "./assets/bg2.png",
  "./assets/bg3.png",
  "./assets/bg4.png"
];

const backgroundLayers = [backgroundPrimary, backgroundSecondary];
let activeBackgroundLayer = 0;
let activeBackgroundIndex = -1;
let backgroundSlideTimer = null;
let backgroundFadeFrame = null;

let activeCard = cards[0];
let toastTimer;
let modalCloseTimer = null;
let uiAudioContext = null;
let uiSoundEnabled = (() => {
  try { return localStorage.getItem("generals-x-ui-sound") !== "off"; }
  catch { return true; }
})();

const uiSoundProfiles = {
  tap: [[310, 250, 0.045, 0.020]],
  select: [[390, 520, 0.070, 0.026], [690, 760, 0.045, 0.012]],
  open: [[260, 390, 0.085, 0.020], [520, 650, 0.070, 0.010]],
  close: [[410, 275, 0.075, 0.018]],
  play: [[180, 230, 0.095, 0.032], [520, 690, 0.090, 0.016]],
  confirm: [[470, 660, 0.080, 0.024]]
};

function ensureUIAudio() {
  if (!uiSoundEnabled) return null;
  if (!uiAudioContext) {
    const AudioContextClass = window.AudioContext || window.webkitAudioContext;
    if (!AudioContextClass) return null;
    uiAudioContext = new AudioContextClass();
  }
  if (uiAudioContext.state === "suspended") uiAudioContext.resume().catch(() => {});
  return uiAudioContext;
}

function triggerHaptic(style = "light") {
  if (!hasРоднойBridge) return;
  window.GeneralsXРодной.request("haptic", { style }, 1200).catch(() => {});
}

function playUISound(name = "tap") {
  if (!uiSoundEnabled) return;
  const context = ensureUIAudio();
  if (!context) return;
  const profile = uiSoundProfiles[name] || uiSoundProfiles.tap;
  const now = context.currentTime;
  profile.forEach(([from, to, duration, volume], index) => {
    const oscillator = context.createOscillator();
    const gain = context.createGain();
    oscillator.type = index === 0 ? "triangle" : "sine";
    oscillator.frequency.setValueAtTime(from, now);
    oscillator.frequency.exponentialRampToValueAtTime(Math.max(40, to), now + duration);
    gain.gain.setValueAtTime(0.0001, now);
    gain.gain.exponentialRampToValueAtTime(volume, now + 0.008);
    gain.gain.exponentialRampToValueAtTime(0.0001, now + duration);
    oscillator.connect(gain);
    gain.connect(context.destination);
    oscillator.start(now);
    oscillator.stop(now + duration + 0.01);
  });
}

function syncAudioToggle() {
  if (!audioToggle) return;
  audioToggle.classList.toggle("is-muted", !uiSoundEnabled);
  audioToggle.setAttribute("aria-pressed", String(!uiSoundEnabled));
  audioToggle.setAttribute("aria-label", uiSoundEnabled ? "Отключить звуки интерфейса" : "Включить звуки интерфейса");
  audioToggle.title = uiSoundEnabled ? "Отключить звуки интерфейса" : "Включить звуки интерфейса";
}

function animateInteraction(target) {
  if (!target) return;
  target.classList.remove("is-pressed");
  void target.offsetWidth;
  target.classList.add("is-pressed");
  window.setTimeout(() => target.classList.remove("is-pressed"), 180);
}

const modCatalog = [
  {
    id: "enhanced",
    title: "Enhanced",
    description: "Modernized Zero Hour profile with its own visual, UI and AI options.",
    author: "Acoustic Alpha",
    moddbUrl: "https://www.moddb.com/mods/cc-generals-zero-hour-enhanced"
  },
  {
    id: "contra-x",
    title: "Contra X",
    description: "Contra X Бета 2 + Patch 1 with dedicated mod settings.",
    author: "Contra Mod Team",
    moddbUrl: "https://www.moddb.com/mods/contra"
  },
  {
    id: "contra-007",
    title: "Contra 007",
    description: "Классический Contra 0.07 с официальными исправлениями ИИ и карт.",
    author: "Contra Mod Team",
    moddbUrl: "https://www.moddb.com/mods/contra/downloads/contra-007"
  }
];

function loadУстановитьedMods() {
  try {
    const saved = JSON.parse(localStorage.getItem("generals-x-launcher-demo-installed-mods") || "[]");
    return Array.isArray(saved) ? saved.filter(id => modCatalog.some(mod => mod.id === id)) : [];
  } catch {
    return [];
  }
}

let installedMods = loadУстановитьedMods();

function saveУстановитьedMods() {
  try {
    localStorage.setItem("generals-x-launcher-demo-installed-mods", JSON.stringify(installedMods));
  } catch {
    // Demo still works without persistent browser storage.
  }
}

function isModУстановитьed(modId) {
  return installedMods.includes(modId);
}

function cardForProfileId(profileId) {
  const cardId = profileId === "online" ? "zero-hour-online" : profileId;
  return cards.find(card => card.dataset.id === cardId) || null;
}

function ensureHomeСкачатьPercent(card) {
  if (!card) return null;
  let indicator = card.querySelector(".mode-card__download-percent");
  if (!indicator) {
    indicator = document.createElement("span");
    indicator.className = "mode-card__download-percent";
    indicator.setAttribute("aria-hidden", "true");
    card.append(indicator);
  }
  return indicator;
}

function setHomeСкачатьProgress(profileId, fraction = 0, active = true) {
  const value = Math.max(0, Math.min(1, Number(fraction || 0)));
  homeСкачатьState.set(profileId, { active, fraction: value });
  const card = cardForProfileId(profileId);
  if (!card) return;

  const pendingУстановить = profileId === "online"
    ? !Boolean(nativeState?.online?.installed)
    : !isModУстановитьed(profileId);
  const indicator = ensureHomeСкачатьPercent(card);

  card.hidden = false;
  card.classList.toggle("is-downloading", active);
  card.classList.toggle("is-download-pending", active && pendingУстановить);
  card.classList.remove("is-download-error", "is-download-complete");

  if (indicator) {
    indicator.textContent = active ? `${Math.round(value * 100)}%` : "";
  }
  updateModesOverflow();
}

function finishHomeСкачать(profileId, outcome) {
  const card = cardForProfileId(profileId);
  homeСкачатьState.delete(profileId);
  if (!card) return;

  const indicator = card.querySelector(".mode-card__download-percent");
  if (indicator) indicator.textContent = "";

  card.classList.remove(
    "is-downloading",
    "is-download-pending",
    "is-download-complete",
    "is-download-error"
  );
  if (outcome === "complete") {
    card.classList.add("is-download-complete");
    window.setTimeout(() => card.classList.remove("is-download-complete"), 650);
  } else if (outcome === "error") {
    card.classList.add("is-download-error");
    window.setTimeout(() => card.classList.remove("is-download-error"), 850);
  }
  syncУстановитьedModCards();
}

function updateModesOverflow() {
  if (!modesRail) return;
  window.requestAnimationFrame(() => {
    const overflowing = modesRail.scrollWidth > modesRail.clientWidth + 2;
    modesRail.classList.toggle("is-overflowing", overflowing);
  });
}

function syncModeCardВерсияs() {
  const baseCard = cards.find(item => item.dataset.id === "zero-hour-online");
  const baseВерсия = nativeState?.online?.installedВерсия || nativeState?.online?.version || "1.04";
  const baseSmall = baseCard?.querySelector("small");
  if (baseSmall) baseSmall.textContent = `${baseВерсия} · Сетевая игра`;

  modCatalog.forEach(mod => {
    const card = cards.find(item => item.dataset.id === mod.id);
    const small = card?.querySelector("small");
    if (!small) return;
    small.textContent = mod.installedВерсия || mod.version || (mod.id === "contra-x" ? "Бета 2 · Patch 1" : "Установитьed");
  });
}

function syncУстановитьedModCards() {
  const hasУстановитьedMods = installedMods.length > 0;
  const baseCard = cards.find(item => item.dataset.id === "zero-hour-online");
  if (baseCard) baseCard.hidden = !hasУстановитьedMods;

  modCatalog.forEach(mod => {
    const card = cards.find(item => item.dataset.id === mod.id);
    const downloading = Boolean(homeСкачатьState.get(mod.id)?.active);
    if (card) card.hidden = !isModУстановитьed(mod.id) && !downloading;
  });

  syncModeCardВерсияs();
  updateModesOverflow();
}

function syncActiveModSourceLink() {
  if (!modSourceLink) return;

  const mod = modCatalog.find(item => item.id === activeCard?.dataset.id);
  const shouldShow = Boolean(mod && isModУстановитьed(mod.id));

  modSourceLink.hidden = !shouldShow;

  if (!shouldShow) {
    modSourceLink.removeAttribute("href");
    modSourceLink.removeAttribute("title");
    return;
  }

  modSourceLink.href = mod.moddbUrl;
  modSourceLink.title = `Оригинальный мод на ModDB — ${mod.author}`;
}

const settingsDefaults = {
  game: {
    shadow3D: false,
    shadow2D: true,
    cloudShadows: false,
    groundLighting: true,
    softWater: true,
    buildingOcclusion: true,
    showProps: true,
    extraAnimations: true,
    dynamicLOD: false,
    heatEffects: false,
    textureQuality: "Высокое",
    particles: "Среднее",
    textureFilter: "Анизотропная",
    anisotropy: "8x",
    msaa: "Выкл.",
    maxCamera: 550,
    minCamera: 70,
    cameraPitch: 37,
    enforceMax: false,
    scrollSpeed: 1.0,
    drawDistance: 1.20,
    fpsLimit: true,
    fps: 60
  },
  enhanced: {
    textureResolution: "Высокое",
    uiQuality: "FHD",
    infantryIconScale: "100%",
    cameos: "HD",
    aiScripts: "По умолчанию"
  },
  contra: {
    controlBar: "Contra",
    cameos: "Стандарт",
    music: "Стандарт",
    voices: "Английский",
    hotkeys: "Оригинал",
    hotkeyLanguage: "Английский",
    portraits: "Стандарт",
    fogEffects: false,
    waterEffects: true,
    extraBuildingProps: true
  }
};

function cloneНастройкиDefaults() {
  return JSON.parse(JSON.stringify(settingsDefaults));
}

function loadDemoНастройки() {
  try {
    const saved = localStorage.getItem("generals-x-launcher-demo-settings");
    if (!saved) return cloneНастройкиDefaults();
    const parsed = JSON.parse(saved);
    return {
      game: { ...settingsDefaults.game, ...(parsed.game || {}) },
      enhanced: { ...settingsDefaults.enhanced, ...(parsed.enhanced || {}) },
      contra: { ...settingsDefaults.contra, ...(parsed.contra || {}) }
    };
  } catch {
    return cloneНастройкиDefaults();
  }
}

let settingsState = loadDemoНастройки();

function showToast(message) {
  window.clearTimeout(toastTimer);
  toast.textContent = message;
  toast.classList.add("is-visible");
  toastTimer = window.setTimeout(() => {
    toast.classList.remove("is-visible");
  }, 2200);
}

function setActiveCard(card) {
  if (!card || card === activeCard) return;

  triggerHaptic("selection");
  cards.forEach(item => item.classList.toggle("is-active", item === card));
  activeCard = card;

  hero.classList.add("is-switching");

  window.setTimeout(() => {
    modeTitle.textContent = card.dataset.title;
    modeTitle.classList.toggle("is-long-title", card.dataset.id === "zero-hour-online");
    modeОписание.textContent = card.dataset.description;
    profileLabel.textContent = card.dataset.profile;
    statusLabel.textContent = card.dataset.status;
    playLabel.textContent = "ИГРАТЬ";

    const experimental = card.dataset.status === "EXPERIMENTAL";
    statusLabel.classList.toggle("status-text--warning", experimental);
    statusLabel.classList.toggle("status-text--готово", !experimental);

    syncActiveModSourceLink();
    if (hasРоднойBridge) syncРоднойSystemСтатус();

    hero.classList.remove("is-switching");
    card.scrollIntoView({ behavior: "smooth", block: "nearest", inline: "nearest" });
  }, 155);
}

cards.forEach(card => {
  card.addEventListener("click", () => setActiveCard(card));
});

playButton.addEventListener("click", async () => {
  const profileId = nativeProfileIdForCard();
  if (!hasРоднойBridge) {
    showToast("Demo: launch request for " + activeCard.dataset.title);
    return;
  }

  const profile = nativeProfileState(profileId);
  const installed = Boolean(profile?.installed);
  const updateAvailable = Boolean(profile?.updateAvailable);

  if (!installed || updateAvailable) {
    try {
      if (profile?.packageURL) {
        downloadMetrics.set(profileId, {
          busy: true,
          profileId,
          paused: false,
          received: 0,
          total: Number(profile.packageBytes || 0),
          fraction: 0
        });
        setHomeСкачатьProgress(profileId, 0, true);
        showToast(`${updateAvailable ? "Обновление" : "Скачатьing"} ${activeCard.dataset.title}…`);
        await nativeRequest("install", { profileId });
        await syncРоднойState();
      } else {
        await nativeRequest("chooseFile", { profileId });
        showToast(`Выберите пакет ${activeCard.dataset.title} package`);
      }
    } catch (error) {
      downloadMetrics.delete(profileId);
      finishHomeСкачать(profileId, "error");
      showToast(error.message || "Ошибка установки");
    }
    return;
  }

  if (profileId !== "online" && !nativeState?.online?.installed) {
    showToast("Сначала установите базовые файлы Zero Hour + Online");
    return;
  }

  try {
    await nativeRequest("play", { profileId });
    showToast(`Запуск ${activeCard.dataset.title}…`);
  } catch (error) {
    showToast(error.message || "Не удалось запустить игру");
  }
});

detailsButton.addEventListener("click", () => {
  openPanel("details");
});

async function handleLauncherEsc() {
  playUISound("close");
  if (modalBackdrop && !modalBackdrop.hidden) { closeModal(); return; }
  showToast("ESC");
}

launcherEsc?.addEventListener("click", handleLauncherEsc);

document.addEventListener("keydown", event => {
  if (event.key === "Escape") handleLauncherEsc();
});

function openPanel(type) {
  window.clearTimeout(modalCloseTimer);
  if (modalHeaderActions) modalHeaderActions.innerHTML = "";
  modalBackdrop.hidden = false;
  window.requestAnimationFrame(() => modalBackdrop.classList.add("is-visible"));

  if (type === "settings") {
    const profileId = nativeProfileIdForCard();

    modalEyebrow.textContent = activeCard.dataset.profile;
    modalTitle.textContent =
      profileId === "enhanced"
        ? "Настройки Enhanced"
        : profileId === "contra-x"
          ? "Настройки Contra X"
          : profileId === "online"
            ? "Настройки Zero Hour + Online"
            : activeCard.dataset.title + " settings";
    if (hasРоднойBridge) {
      try {
        const nativeНастройки = await nativeRequest("settingsGet", { profileId });
        const scope = profileId === "enhanced" ? "enhanced" : profileId === "contra-x" ? "contra" : "game";
        settingsState[scope] = { ...settingsDefaults[scope], ...(nativeНастройки?.values || {}) };
      } catch (error) {
        showToast(error.message || "Не удалось загрузить настройки");
      }
    }
    renderНастройки(profileId);
  } else if (type === "mods") {
    modalEyebrow.textContent = "GENERALS X";
    modalTitle.textContent = "Добавить мод";
    renderModLibrary();
  } else if (type === "diagnostics") {
    modalEyebrow.textContent = "SYSTEM";
    modalTitle.textContent = "Диагностика";
    renderДиагностика();
  } else {
    modalEyebrow.textContent = activeCard.dataset.profile;
    modalTitle.textContent = activeCard.dataset.title;
    modalBody.innerHTML = `
      <div class="setting-section">
        <h3>Информация о профиле</h3>
        <div class="setting-row"><span>Статус</span><strong>${activeCard.dataset.status}</strong></div>
        <div class="setting-row"><span>Платформа</span><strong>iPad / Mac</strong></div>
        <div class="setting-row"><span>Режим лаунчера</span><strong>Web UI · системный мост</strong></div>
      </div>
      <div class="setting-section">
        <h3>Описание</h3>
        <p style="margin:0;color:rgba(255,255,255,.68);font-size:13px;line-height:1.7">${activeCard.dataset.description}</p>
      </div>
    `;
  }
}


function humanSize(bytes) {
  const value = Number(bytes || 0);
  if (!value) return "";
  if (value >= 1024 ** 3) return `${(value / 1024 ** 3).toFixed(1)} GB`;
  if (value >= 1024 ** 2) return `${(value / 1024 ** 2).toFixed(0)} MB`;
  return `${Math.round(value / 1024)} KB`;
}

function formatBytesCompact(bytes) {
  const value = Number(bytes || 0);
  if (!value) return "";
  if (value >= 1024 ** 3) return `${(value / 1024 ** 3).toFixed(2)} GB`;
  if (value >= 1024 ** 2) return `${(value / 1024 ** 2).toFixed(0)} MB`;
  return `${Math.max(1, Math.round(value / 1024))} KB`;
}

function formatSpeed(bytesPerSecond) {
  const value = Number(bytesPerSecond || 0);
  if (value < 1024) return "";
  if (value >= 1024 ** 2) return `${(value / 1024 ** 2).toFixed(value >= 10 * 1024 ** 2 ? 1 : 2)} MB/s`;
  return `${(value / 1024).toFixed(0)} KB/s`;
}

function formatEta(seconds) {
  const value = Math.max(0, Math.round(Number(seconds || 0)));
  if (!value || value > 24 * 60 * 60) return "";
  if (value < 60) return `~${value}s`;
  if (value < 3600) return `~${Math.ceil(value / 60)}m`;
  const hours = Math.floor(value / 3600);
  const minutes = Math.ceil((value % 3600) / 60);
  return `~${hours}h ${minutes}m`;
}

function currentСкачатьMetrics(profileId) {
  if (downloadMetrics.has(profileId)) return downloadMetrics.get(profileId);
  if (nativeState?.download?.busy && nativeState.download.profileId === profileId) {
    return nativeState.download;
  }
  return null;
}

function downloadСтатусText(profileId) {
  const metrics = currentСкачатьMetrics(profileId);
  if (!metrics) return "";
  const parts = [];
  const percent = Math.round(Math.max(0, Math.min(1, Number(metrics.fraction || 0))) * 100);
  parts.push(metrics.paused ? `Пауза · ${percent}%` : `${percent}%`);
  const received = formatBytesCompact(metrics.received);
  const total = formatBytesCompact(metrics.total);
  if (received && total) parts.push(`${received} / ${total}`);
  else if (received) parts.push(received);
  const speed = formatSpeed(metrics.speedBytesPerSecond);
  if (!metrics.paused && speed) parts.push(speed);
  const eta = formatEta(metrics.etaSeconds);
  if (!metrics.paused && eta) parts.push(eta);
  return parts.join(" · ");
}

function modВерсияSummary(mod) {
  const nativeMod = nativeModState(mod.id);
  const installed = isModУстановитьed(mod.id);
  const current = nativeMod?.installedВерсия || mod.installedВерсия || "";
  const available = nativeMod?.version || mod.version || "";
  const updateAvailable = Boolean(nativeMod?.updateAvailable || mod.updateAvailable) &&
    Boolean(available) && available !== current;

  if (!installed) {
    return `
      <div class="mod-version-summary">
        <span><em>Версия</em><strong>${available || "Неизвестно"}</strong></span>
        ${mod.packageBytes ? `<span><em>Скачать</em><strong>${humanSize(mod.packageBytes)}</strong></span>` : ""}
      </div>`;
  }

  return `
    <div class="mod-version-summary">
      <span><em>Текущая</em><strong>${current || "Неизвестно"}</strong></span>
      ${updateAvailable ? `<span class="has-update"><em>Новая</em><strong>${available}</strong></span>` : ""}
    </div>`;
}

function modУстановитьActions(mod) {
  const nativeMod = nativeModState(mod.id);
  const installed = isModУстановитьed(mod.id);
  const download = currentСкачатьMetrics(mod.id);
  const activeСкачать = Boolean(download?.busy);
  const busy = Boolean(nativeState?.download?.busy);
  const updateAvailable = Boolean(nativeMod?.updateAvailable || mod.updateAvailable) &&
    Boolean(nativeMod?.version || mod.version) &&
    (nativeMod?.version || mod.version) !== (nativeMod?.installedВерсия || mod.installedВерсия || "");

  if (activeСкачать) return "";

  if (installed) {
    return `
      ${updateAvailable ? `
        <button type="button" class="mod-install-button mod-install-button--primary" data-mod-download="${mod.id}" ${busy ? "disabled" : ""}>
          Обновить
        </button>` : ""}
      <button type="button" class="mod-install-button" data-mod-remove="${mod.id}" ${busy ? "disabled" : ""}>Удалить</button>
    `;
  }

  return `
    <button type="button" class="mod-install-button mod-install-button--primary" data-mod-download="${mod.id}" ${busy ? "disabled" : ""}>
      <svg class="lucide lucide-cloud-download" viewBox="0 0 24 24" aria-hidden="true">
        <path d="M12 13v8M8 17l4 4 4-4"/>
        <path d="M20.39 18.39A5 5 0 0 0 18 9h-1.26A8 8 0 1 0 3 16.3"/>
      </svg>
      Скачать
    </button>
    <button type="button" class="mod-install-button" data-mod-file="${mod.id}" ${busy ? "disabled" : ""}>
      <svg class="lucide lucide-file-up" viewBox="0 0 24 24" aria-hidden="true">
        <path d="M14.5 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7.5L14.5 2z"/>
        <polyline points="14 2 14 8 20 8"/>
        <path d="M12 18v-6M9 15l3-3 3 3"/>
      </svg>
      Выбрать файл
    </button>
    <input class="mod-file-input" type="file" data-mod-file-input="${mod.id}">
  `;
}

function modСкачатьPanel(mod) {
  const metrics = currentСкачатьMetrics(mod.id);
  if (!metrics?.busy) return "";
  const fraction = Math.max(0, Math.min(1, Number(metrics.fraction || 0)));
  return `
    <div class="mod-download-panel" data-mod-progress="${mod.id}">
      <div class="mod-download-track" aria-label="Скачать progress">
        <span style="width:${Math.round(fraction * 100)}%"></span>
      </div>
      <div class="mod-download-status" data-download-status="${mod.id}">${downloadСтатусText(mod.id)}</div>
      <div class="mod-download-controls">
        <button type="button" class="mod-download-control" data-download-toggle="${mod.id}">
          ${metrics.paused ? "Продолжить" : "Пауза"}
        </button>
        <button type="button" class="mod-download-control mod-download-control--cancel" data-download-cancel="${mod.id}">Отмена</button>
      </div>
    </div>
  `;
}

function updateСкачатьPanel(profileId) {
  const metrics = currentСкачатьMetrics(profileId);
  const panel = document.querySelector(`[data-mod-progress="${profileId}"]`);
  if (!panel || !metrics) {
    if (!modalBackdrop.hidden && modalTitle.textContent === "Добавить мод") renderModLibrary();
    return;
  }
  const bar = panel.querySelector(".mod-download-track span");
  const status = panel.querySelector(`[data-download-status="${profileId}"]`);
  const toggle = panel.querySelector(`[data-download-toggle="${profileId}"]`);
  const fraction = Math.max(0, Math.min(1, Number(metrics.fraction || 0)));
  if (bar) bar.style.width = `${Math.round(fraction * 100)}%`;
  if (status) status.textContent = downloadСтатусText(profileId);
  if (toggle) toggle.textContent = metrics.paused ? "Продолжить" : "Пауза";
}

function renderModLibrary() {
  modalBody.innerHTML = `
    <div class="mod-library">
      <div class="mod-library__toolbar">
        <div class="segment-control mod-channel-control">
          <button type="button" data-channel="stable" class="${(nativeState?.channel || "stable") === "stable" ? "is-selected" : ""}">Стабильная</button>
          <button type="button" data-channel="beta" class="${nativeState?.channel === "beta" ? "is-selected" : ""}">Бета</button>
        </div>
        <button type="button" class="diagnostics-action" data-catalog-refresh>Обновить</button>
      </div>
      <p class="mod-library__intro">Установить or update profiles from the Generals X catalog. Only one large package is downloaded at a time.</p>
      ${modCatalog.map(mod => `
        <div class="mod-library-card" data-mod-card="${mod.id}">
          <div class="mod-library-card__main">
            <div class="mod-library-card__copy">
              <strong>${mod.title}</strong>
              <span>${mod.description}</span>
              ${modВерсияSummary(mod)}
              ${mod.fallbackChannel ? `<span class="mod-channel-note">${mod.fallbackChannel.toUpperCase()} package fallback</span>` : ""}
              <a class="mod-author-link" href="${mod.moddbUrl}" target="_blank" rel="noopener noreferrer">
                <svg class="lucide lucide-external-link" viewBox="0 0 24 24" aria-hidden="true">
                  <path d="M15 3h6v6"/>
                  <path d="M10 14 21 3"/>
                  <path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/>
                </svg>
                Оригинальный мод от ${mod.author} · ModDB
              </a>
            </div>
            <div class="mod-library-card__actions">
              ${modУстановитьActions(mod)}
            </div>
          </div>
          ${modСкачатьPanel(mod)}
        </div>
      `).join("")}
    </div>
  `;

  modalBody.querySelectorAll("[data-mod-download]").forEach(button => {
    button.addEventListener("click", () => {
      if (hasРоднойBridge) installРоднойMod(button.dataset.modСкачать, button);
      else simulateCloudУстановить(button.dataset.modСкачать, button);
    });
  });

  modalBody.querySelectorAll("[data-mod-remove]").forEach(button => {
    button.addEventListener("click", async () => {
      try {
        const state = await nativeRequest("remove", { profileId: button.dataset.modУдалить });
        applyРоднойState(state);
        showToast("Мод удалён");
      } catch (error) {
        showToast(error.message || "Удалить failed");
      }
    });
  });

  modalBody.querySelectorAll("[data-download-toggle]").forEach(button => {
    button.addEventListener("click", async () => {
      const profileId = button.dataset.downloadToggle;
      const metrics = currentСкачатьMetrics(profileId);
      if (!metrics) return;
      try {
        const action = metrics.paused ? "resumeСкачать" : "pauseСкачать";
        applyРоднойState(await nativeRequest(action, { profileId }));
        const latest = nativeState?.download;
        if (latest?.profileId === profileId) downloadMetrics.set(profileId, latest);
        updateСкачатьPanel(profileId);
        showToast(metrics.paused ? "Скачать resumed" : "Скачать paused");
      } catch (error) {
        showToast(error.message || "Скачать control failed");
      }
    });
  });

  modalBody.querySelectorAll("[data-download-cancel]").forEach(button => {
    button.addEventListener("click", async () => {
      const profileId = button.dataset.downloadОтмена;
      try {
        await nativeRequest("cancelСкачать", { profileId });
        button.disabled = true;
        showToast("Отменаling download…");
      } catch (error) {
        showToast(error.message || "Отмена failed");
      }
    });
  });

  modalBody.querySelectorAll("[data-channel]").forEach(button => {
    button.addEventListener("click", async () => {
      if (!hasРоднойBridge) return;
      try {
        applyРоднойState(await nativeRequest("setChannel", { channel: button.dataset.channel }));
        showToast(`${button.dataset.channel.toUpperCase()} channel active`);
      } catch (error) {
        showToast(error.message || "Не удалось сменить канал");
      }
    });
  });

  modalBody.querySelector("[data-catalog-refresh]")?.addEventListener("click", async () => {
    if (!hasРоднойBridge) return;
    try {
      applyРоднойState(await nativeRequest("refreshCatalog"));
      showToast("Каталог обновлён");
    } catch (error) {
      showToast(error.message || "Обновить failed");
    }
  });

  modalBody.querySelectorAll("[data-mod-file]").forEach(button => {
    button.addEventListener("click", () => {
      if (hasРоднойBridge) {
        nativeRequest("chooseFile", { profileId: button.dataset.modFile })
          .catch(error => showToast(error.message || "Не удалось открыть выбор файла"));
        return;
      }
      const input = modalBody.querySelector(`[data-mod-file-input="${button.dataset.modFile}"]`);
      input?.click();
    });
  });

  modalBody.querySelectorAll("[data-mod-file-input]").forEach(input => {
    input.addEventListener("change", () => {
      if (!input.files || input.files.length === 0) return;
      installMod(input.dataset.modFileInput, "file");
    });
  });
}


async function installРоднойMod(modId, button) {
  const mod = modCatalog.find(item => item.id === modId);
  if (!mod) return;

  button.disabled = true;
  downloadMetrics.set(modId, { busy: true, profileId: modId, paused: false, received: 0, total: mod.packageBytes || 0, fraction: 0 });
  setHomeСкачатьProgress(modId, 0, true);
  const fallbackNote = mod.fallbackChannel ? ` · using ${mod.fallbackChannel.toUpperCase()} package` : "";
  showToast(`Загрузка ${mod.title}${fallbackNote}…`);
  try {
    await nativeRequest("install", { profileId: modId });
    await syncРоднойState();
  } catch (error) {
    downloadMetrics.delete(modId);
    finishHomeСкачать(modId, "error");
    button.disabled = false;
    showToast(error.message || "Скачать failed");
  }
}

function simulateCloudУстановить(modId, button) {
  const card = button.closest("[data-mod-card]");
  const progress = card?.querySelector(`[data-mod-progress="${modId}"]`);
  const bar = progress?.querySelector("span");
  const buttons = card?.querySelectorAll(".mod-install-button") || [];

  buttons.forEach(item => item.disabled = true);
  if (progress) progress.style.display = "block";

  let value = 0;
  const timer = window.setInterval(() => {
    value = Math.min(100, value + 12);
    if (bar) bar.style.width = `${value}%`;

    if (value >= 100) {
      window.clearInterval(timer);
      window.setTimeout(() => installMod(modId, "cloud"), 180);
    }
  }, 95);
}

function installMod(modId, source) {
  const mod = modCatalog.find(item => item.id === modId);
  if (!mod) return;

  if (!isModУстановитьed(modId)) {
    installedMods.push(modId);
    saveУстановитьedMods();
  }

  syncУстановитьedModCards();

  const card = cards.find(item => item.dataset.id === modId);
  if (card) setActiveCard(card);

  showToast(`${mod.title} installed${source === "file" ? " from file" : ""}`);
  window.setTimeout(closePanel, 220);
}

function diagnosticsReport() {
  return `APP
Project: Generals X
Bundle: demo
Platform: Local browser
Device: ${navigator.platform || "Неизвестно"}

BUILD
Launcher: demo-01
Запуск лаунчера: local
Engine: 0.1.0
Запуск базовой оболочки: local

CONTENT
Файлы игры: Установитьed
Zero Hour + Online: Установитьed
Enhanced: ${isModУстановитьed("enhanced") ? "Установитьed" : "Не установлено"}
Contra X: ${isModУстановитьed("contra") ? "Установитьed" : "Не установлено"}

FILES
iPad settings: Есть
Настройки Enhanced: ${isModУстановитьed("enhanced") ? "Есть" : "n/a"}
Contra settings: ${isModУстановитьed("contra") ? "Есть" : "n/a"}
Текущая session: Yes
Session logs: 1/10`;
}

function renderДиагностика() {
  modalBody.innerHTML = `
    <p class="diagnostics-note">Build, installed content and crash logs. A copy is saved automatically to Files > On My iPad > Generals ZH > Диагностика.</p>
    <div class="diagnostic-block" id="diagnosticReport">${diagnosticsReport()}</div>
    <div class="diagnostics-actions">
      <button type="button" class="diagnostics-action" data-diagnostics-refresh>Обновить</button>
      <button type="button" class="diagnostics-action" data-diagnostics-export>Сохранить в Файлы</button>
      <button type="button" class="diagnostics-action" data-diagnostics-share>Поделиться отчётом и логами</button>
      <button type="button" class="diagnostics-action diagnostics-action--danger" data-diagnostics-clear>Очистить логи</button>
    </div>
  `;

  const refreshДиагностика = async () => {
    if (!hasРоднойBridge) {
      modalBody.querySelector("#diagnosticReport").textContent = diagnosticsReport();
      showToast("Диагностика refreshed");
      return;
    }
    try {
      const result = await nativeRequest("diagnostics");
      nativeДиагностикаText = result?.report || "";
      modalBody.querySelector("#diagnosticReport").textContent = nativeДиагностикаText || "Диагностика недоступна.";
      if (result?.exportPath) showToast(`Диагностика saved: ${result.exportPath}`);
    } catch (error) {
      modalBody.querySelector("#diagnosticReport").textContent = error.message || "Диагностика failed";
    }
  };

  modalBody.querySelector("[data-diagnostics-refresh]").addEventListener("click", refreshДиагностика);
  if (hasРоднойBridge) refreshДиагностика();

  modalBody.querySelector("[data-diagnostics-export]").addEventListener("click", async () => {
    if (!hasРоднойBridge) {
      showToast("Родной bridge is unavailable");
      return;
    }
    showToast("Сохранение диагностики в Файлы…");
    try {
      const result = await nativeRequest("exportДиагностика");
      showToast(`Сохранитьd ${result?.fileCount || 0} files · ${result?.path || "Диагностика"}`);
    } catch (error) {
      showToast(error.message || "Сохранить failed");
    }
  });

  modalBody.querySelector("[data-diagnostics-share]").addEventListener("click", async () => {
    if (hasРоднойBridge) {
      showToast("Открытие меню «Поделиться»…");
      try {
        await nativeRequest("shareДиагностика");
      } catch (error) {
        showToast(error.message || "Не удалось поделиться");
      }
      return;
    }
    const report = diagnosticsReport();
    try {
      if (navigator.share) {
        await navigator.share({ title: "Диагностика Generals X", text: report });
      } else if (navigator.clipboard) {
        await navigator.clipboard.writeText(report);
        showToast("Отчёт скопирован");
      } else {
        showToast("Поделиться в этом браузере невозможно");
      }
    } catch {
      // User cancellation is not an error for this demo.
    }
  });

  modalBody.querySelector("[data-diagnostics-clear]").addEventListener("click", async () => {
    if (hasРоднойBridge) {
      try {
        await nativeRequest("clearДиагностика");
        showToast("Открыто окно очистки");
      } catch (error) {
        showToast(error.message || "Не удалось очистить");
      }
    } else {
      showToast("Демо-логи очищены");
    }
  });
}

function segmentControl(scope, key, choices) {
  const value = settingsState[scope][key];
  return `
    <div class="segment-control" data-scope="${scope}" data-key="${key}">
      ${choices.map(choice => `
        <button type="button" class="${choice === value ? "is-selected" : ""}" data-value="${choice}">${choice}</button>
      `).join("")}
    </div>
  `;
}

function toggleControl(scope, key) {
  const enabled = Boolean(settingsState[scope][key]);
  return `
    <button type="button" class="switch-control ${enabled ? "is-on" : ""}" data-scope="${scope}" data-key="${key}" aria-pressed="${enabled}">
      <span></span>
    </button>
  `;
}

function rangeControl(scope, key, min, max, step, suffix = "") {
  const value = settingsState[scope][key];
  return `
    <div class="range-control">
      <input type="range" min="${min}" max="${max}" step="${step}" value="${value}" data-scope="${scope}" data-key="${key}">
      <output>${value}${suffix}</output>
    </div>
  `;
}

function settingRow(label, control) {
  return `<div class="setting-row"><span>${label}</span><div class="setting-control">${control}</div></div>`;
}

function renderGameНастройки() {
  return `
    <div class="setting-section">
      <h3>Графика</h3>
      ${settingRow("Тени 3D", toggleControl("game", "shadow3D"))}
      ${settingRow("Тени 2D", toggleControl("game", "shadow2D"))}
      ${settingRow("Тени облаков", toggleControl("game", "cloudShadows"))}
      ${settingRow("Освещение земли", toggleControl("game", "groundLighting"))}
      ${settingRow("Сглаженные границы воды", toggleControl("game", "softWater"))}
      ${settingRow("Юниты за зданиями", toggleControl("game", "buildingOcclusion"))}
      ${settingRow("Мелкие объекты / деревья", toggleControl("game", "showProps"))}
      ${settingRow("Дополнительные анимации", toggleControl("game", "extraAnimations"))}
      ${settingRow("Динамический LOD", toggleControl("game", "dynamicLOD"))}
      ${settingRow("Эффекты жары", toggleControl("game", "heatEffects"))}
      ${settingRow("Качество текстур", segmentControl("game", "textureQuality", ["Высокое", "Среднее", "Низкое"]))}
      ${settingRow("Частицы", segmentControl("game", "particles", ["Низкое", "Среднее", "Высокое"]))}
      ${settingRow("Фильтрация текстур", segmentControl("game", "textureFilter", ["Билинейная", "Трилинейная", "Анизотропная"]))}
      ${settingRow("Анизотропия", segmentControl("game", "anisotropy", ["2x", "4x", "8x", "16x"]))}
      ${settingRow("MSAA", segmentControl("game", "msaa", ["Выкл.", "2x", "4x", "8x"]))}
    </div>

    <div class="setting-section">
      <h3>Камера / производительность</h3>
      ${settingRow("Максимальная высота камеры", rangeControl("game", "maxCamera", 300, 800, 10))}
      ${settingRow("Минимальная высота камеры", rangeControl("game", "minCamera", 40, 150, 5))}
      ${settingRow("Наклон камеры", rangeControl("game", "cameraPitch", 20, 60, 1, "°"))}
      ${settingRow("Ограничить максимальную высоту камеры", toggleControl("game", "enforceMax"))}
      ${settingRow("Скорость прокрутки клавиатурой / у края", rangeControl("game", "scrollSpeed", 0.5, 2, 0.1, "×"))}
      ${settingRow("Дальность прорисовки местности", rangeControl("game", "drawDistance", 0.5, 2, 0.05, "×"))}
      ${settingRow("Ограничение FPS", toggleControl("game", "fpsLimit"))}
      ${settingRow("Кадров в секунду", rangeControl("game", "fps", 30, 120, 5, " FPS"))}
    </div>
  `;
}

function renderEnhancedНастройки() {
  return `
    <div class="setting-section">
      <h3>Enhanced</h3>
      ${settingRow("Текстуры фракций", segmentControl("enhanced", "textureResolution", ["Vanilla", "Высокое"]))}
      ${settingRow("Качество интерфейса", segmentControl("enhanced", "uiQuality", ["HD", "FHD", "QHD"]))}
      ${settingRow("Иконки пехоты", segmentControl("enhanced", "infantryIconScale", ["100%", "75%", "50%"]))}
      ${settingRow("Cameos", segmentControl("enhanced", "cameos", ["SD", "HD"]))}
      ${settingRow("Скрипты ИИ", segmentControl("enhanced", "aiScripts", ["По умолчанию", "Ограниченный", "Скайнет"]))}
    </div>
  `;
}

function renderContraНастройки() {
  return `
    <div class="setting-section">
      <h3>Contra X</h3>
      ${settingRow("Панель управления", segmentControl("contra", "controlBar", ["Contra", "Профессиональный", "Стандарт"]))}
      ${settingRow("Качество иконок / камео", segmentControl("contra", "cameos", ["Стандарт", "HD"]))}
      ${settingRow("Музыка", segmentControl("contra", "music", ["Стандарт", "Enhanced", "Саундтрек"]))}
      ${settingRow("Голоса юнитов", segmentControl("contra", "voices", ["Английский", "Родной"]))}
      ${settingRow("Горячие клавиши", segmentControl("contra", "hotkeys", ["Оригинал", "Leikeze"]))}
      ${settingRow("Язык горячих клавиш", segmentControl("contra", "hotkeyLanguage", ["Английский", "Russian"]))}
      ${settingRow("Портреты генералов", segmentControl("contra", "portraits", ["Стандарт", "Забавные"]))}
      ${settingRow("Эффекты тумана", toggleControl("contra", "fogEffects"))}
      ${settingRow("Эффекты воды", toggleControl("contra", "waterEffects"))}
      ${settingRow("Дополнительные объекты зданий", toggleControl("contra", "extraBuildingProps"))}
    </div>
  `;
}

function renderНастройки(profileId = "zero-hour-online") {
  const scope =
    profileId === "enhanced"
      ? "enhanced"
      : profileId === "contra-x"
        ? "contra"
        : "game";

  const content =
    scope === "enhanced"
      ? renderEnhancedНастройки()
      : scope === "contra"
        ? renderContraНастройки()
        : renderGameНастройки();

  modalBody.innerHTML = `
    <div class="settings-content">
      ${content}
    </div>
  `;

  if (modalHeaderActions) {
    modalHeaderActions.innerHTML = `
      <button type="button" class="page-header-action" data-settings-reset>Сбросить</button>
      <button type="button" class="page-header-action page-header-action--primary" data-settings-save>Сохранить</button>
    `;
  }

  modalBody.querySelectorAll(".segment-control button").forEach(button => {
    button.addEventListener("click", () => {
      const parent = button.closest(".segment-control");
      settingsState[parent.dataset.scope][parent.dataset.key] = button.dataset.value;
      parent.querySelectorAll("button").forEach(item => item.classList.toggle("is-selected", item === button));
    });
  });

  modalBody.querySelectorAll(".switch-control").forEach(button => {
    button.addEventListener("click", () => {
      const scope = button.dataset.scope;
      const key = button.dataset.key;
      settingsState[scope][key] = !settingsState[scope][key];
      button.classList.toggle("is-on", settingsState[scope][key]);
      button.setAttribute("aria-pressed", String(settingsState[scope][key]));
    });
  });

  modalBody.querySelectorAll(".range-control input").forEach(input => {
    input.addEventListener("input", () => {
      const scope = input.dataset.scope;
      const key = input.dataset.key;
      const value = Number(input.value);
      settingsState[scope][key] = value;
      const suffix = key === "cameraPitch" ? "°" : key === "fps" ? " FPS" : ["scrollSpeed", "drawDistance"].includes(key) ? "×" : "";
      input.parentElement.querySelector("output").textContent = value + suffix;
    });
  });

  modalHeaderActions?.querySelector("[data-settings-save]")?.addEventListener("click", async () => {
    try {
      if (hasРоднойBridge) {
        await nativeRequest("settingsСохранить", { profileId, values: settingsState[scope] });
      } else {
        localStorage.setItem("generals-x-launcher-demo-settings", JSON.stringify(settingsState));
      }
      triggerHaptic("success");
      showToast(`${activeCard.dataset.title} settings saved`);
    } catch (error) {
      showToast(error.message || "Настройки save failed");
    }
  });

  modalHeaderActions?.querySelector("[data-settings-reset]")?.addEventListener("click", () => {
    settingsState[scope] = { ...settingsDefaults[scope] };
    renderНастройки(profileId);
    showToast("Настройки по умолчанию загружены");
  });
}

const backgroundImageCache = new Map();

function preloadBackgroundSlide(src) {
  if (backgroundImageCache.has(src)) return backgroundImageCache.get(src);
  const promise = new Promise(resolve => {
    const image = new Image();
    let settled = false;
    const finish = async () => {
      if (settled) return;
      settled = true;
      try {
        if (typeof image.decode === "function") await image.decode();
      } catch {
        // A completed load is still usable even when decode() rejects.
      }
      resolve(src);
    };
    image.onload = finish;
    image.onerror = finish;
    image.src = src;
    if (image.complete) finish();
  });
  backgroundImageCache.set(src, promise);
  return promise;
}

function preloadBackgroundSlides() {
  return Promise.all(backgroundSlides.map(preloadBackgroundSlide));
}

function randomBackgroundIndex(excludeIndex = -1) {
  const choices = backgroundSlides
    .map((_, index) => index)
    .filter(index => index !== excludeIndex);

  return choices[Math.floor(Math.random() * choices.length)];
}

function scheduleNextBackgroundSlide() {
  window.clearTimeout(backgroundSlideTimer);
  const delay = 10000 + Math.random() * 5000;
  backgroundSlideTimer = window.setTimeout(showNextBackgroundSlide, delay);
}

async function showNextBackgroundSlide() {
  if (!backgroundPrimary || !backgroundSecondary) return;

  const nextIndex = randomBackgroundIndex(activeBackgroundIndex);
  await preloadBackgroundSlide(backgroundSlides[nextIndex]);
  const nextLayerIndex = activeBackgroundLayer === 0 ? 1 : 0;
  const currentLayer = backgroundLayers[activeBackgroundLayer];
  const nextLayer = backgroundLayers[nextLayerIndex];

  if (backgroundFadeFrame !== null) {
    cancelAnimationFrame(backgroundFadeFrame);
    backgroundFadeFrame = null;
  }

  nextLayer.style.backgroundImage = 'url("' + backgroundSlides[nextIndex] + '")';
  nextLayer.style.opacity = "0";
  currentLayer.style.opacity = "1";

  const fadeDuration = 7600;
  const fadeStart = performance.now();

  function fadeFrame(now) {
    const progress = Math.min(1, (now - fadeStart) / fadeDuration);
    const eased = progress * progress * progress * (progress * (progress * 6 - 15) + 10);

    nextLayer.style.opacity = String(eased);
    currentLayer.style.opacity = String(1 - eased);

    if (progress < 1) {
      backgroundFadeFrame = requestAnimationFrame(fadeFrame);
      return;
    }

    nextLayer.style.opacity = "1";
    currentLayer.style.opacity = "0";
    backgroundFadeFrame = null;
    activeBackgroundLayer = nextLayerIndex;
    activeBackgroundIndex = nextIndex;
    scheduleNextBackgroundSlide();
  }

  backgroundFadeFrame = requestAnimationFrame(fadeFrame);
}

async function startBackgroundMotion() {
  if (!backgroundPrimary || !backgroundSecondary) return;

  activeBackgroundIndex = randomBackgroundIndex();
  const firstSource = backgroundSlides[activeBackgroundIndex];
  await preloadBackgroundSlide(firstSource);
  backgroundPrimary.style.backgroundImage = 'url("' + firstSource + '")';
  backgroundPrimary.style.opacity = "1";
  backgroundSecondary.style.opacity = "0";

  preloadBackgroundSlides().then(() => {
    scheduleNextBackgroundSlide();
  });

  let parallaxX = 0;
  let parallaxY = 0;
  let targetX = 0;
  let targetY = 0;

  window.addEventListener("pointermove", event => {
    targetX = -(event.clientX / window.innerWidth - 0.5) * 8;
    targetY = -(event.clientY / window.innerHeight - 0.5) * 5;
  }, { passive: true });

  window.addEventListener("pointerleave", () => {
    targetX = 0;
    targetY = 0;
  });

  const start = performance.now();

  function frame(now) {
    const elapsed = now - start;
    parallaxX += (targetX - parallaxX) * 0.014;
    parallaxY += (targetY - parallaxY) * 0.014;

    const driftX = elapsed * 0.0088;
    const driftY = elapsed * 0.0034;
    const waveX = Math.sin(elapsed / 7600) * 9;
    const waveY = Math.cos(elapsed / 9200) * 5;

    const primaryX = driftX + waveX + parallaxX;
    const primaryY = driftY + waveY + parallaxY;
    const secondaryX = driftX + waveX * 0.82 + parallaxX * 0.8 + 34;
    const secondaryY = driftY + waveY * 0.82 + parallaxY * 0.8 + 18;

    backgroundPrimary.style.backgroundPosition =
      primaryX + "px " + primaryY + "px";

    backgroundSecondary.style.backgroundPosition =
      secondaryX + "px " + secondaryY + "px";

    if (backgroundGrid) {
      backgroundGrid.style.transform =
        "translate3d(" + (-parallaxX * 0.14) + "px, " + (-parallaxY * 0.14) + "px, 0)";
    }

    requestAnimationFrame(frame);
  }

  requestAnimationFrame(frame);
}

document.querySelectorAll("[data-panel]").forEach(button => {
  button.addEventListener("click", () => openPanel(button.dataset.panel));
});

if (audioToggle) {
  syncAudioToggle();
  audioToggle.addEventListener("click", () => {
    uiSoundEnabled = !uiSoundEnabled;
    try { localStorage.setItem("generals-x-ui-sound", uiSoundEnabled ? "on" : "off"); } catch {}
    syncAudioToggle();
    if (uiSoundEnabled) playUISound("confirm");
    showToast(uiSoundEnabled ? "Звуки интерфейса включены" : "Звуки интерфейса выключены");
  });
}

document.addEventListener("pointerdown", event => {
  const target = event.target.closest("button, a");
  if (!target || target.disabled) return;
  animateInteraction(target);
  const sound = target === playButton
    ? "play"
    : target.classList.contains("mode-card")
      ? "select"
      : target === modalClose
        ? "close"
        : target.matches("[data-panel]")
          ? "open"
          : "tap";
  playUISound(sound);

  const haptic = target === playButton
    ? "medium"
    : target.classList.contains("mode-card")
      ? null
      : target.classList.contains("add-mod-card") || target.matches("[data-panel]")
        ? "light"
        : target === modalClose
          ? "soft"
          : "light";
  if (haptic) triggerHaptic(haptic);
}, { passive: true });

if (modesRail) {
  modesRail.addEventListener("wheel", event => {
    if (!modesRail.classList.contains("is-overflowing")) return;
    if (Math.abs(event.deltaY) <= Math.abs(event.deltaX)) return;
    event.preventDefault();
    modesRail.scrollBy({ left: event.deltaY, behavior: "smooth" });
  }, { passive: false });

  if (window.ResizeObserver) {
    const railObserver = new ResizeObserver(updateModesOverflow);
    railObserver.observe(modesRail);
  } else {
    window.addEventListener("resize", updateModesOverflow, { passive: true });
  }
}

function closePanel() {
  if (modalBackdrop.hidden) return;
  modalBackdrop.classList.remove("is-visible");
  window.clearTimeout(modalCloseTimer);
  modalCloseTimer = window.setTimeout(() => {
    modalBackdrop.hidden = true;
  }, 320);
}

modalClose.addEventListener("click", closePanel);
modalBackdrop.addEventListener("click", event => {
  if (event.target === modalBackdrop) closePanel();
});

window.addEventListener("keydown", event => {
  if (event.key === "Escape") closePanel();

  if (["ArrowLeft", "ArrowRight"].includes(event.key)) {
    const visibleCards = cards.filter(card => !card.hidden);
    const currentIndex = visibleCards.indexOf(activeCard);
    const delta = event.key === "ArrowRight" ? 1 : -1;
    const next = visibleCards[(currentIndex + delta + visibleCards.length) % visibleCards.length];
    if (next) {
      setActiveCard(next);
      next.focus();
    }
  }
});

syncУстановитьedModCards();
syncActiveModSourceLink();
updateModesOverflow();

startBackgroundMotion();

if (hasРоднойBridge) {
  syncРоднойState();
}