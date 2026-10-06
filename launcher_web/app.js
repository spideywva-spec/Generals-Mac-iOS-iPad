const hasNativeBridge = Boolean(window.webkit?.messageHandlers?.generalsX);
const nativePending = new Map();
let nativeRequestCounter = 0;
let nativeState = null;
let nativeDiagnosticsText = "";
const homeDownloadState = new Map();
const downloadMetrics = new Map();

window.GeneralsXNative = {
  request(action, payload = {}, timeoutMs = 20000) {
    if (!hasNativeBridge) return Promise.reject(new Error("Нативный мост недоступен"));
    const id = `gx-${Date.now()}-${++nativeRequestCounter}`;
    return new Promise((resolve, reject) => {
      const timer = window.setTimeout(() => {
        nativePending.delete(id);
        reject(new Error(`Превышено время ожидания действия: ${action}`));
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
      else pending.reject(new Error(envelope.error || "Ошибка запроса к нативному модулю"));
      return;
    }

    if (envelope.type === "event") {
      handleNativeEvent(envelope.name, envelope.payload || {});
    }
  }
};

function nativeRequest(action, payload = {}) {
  return window.GeneralsXNative.request(action, payload);
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

function applyNativeState(state) {
  if (!state || typeof state !== "object") return;
  nativeState = state;

  installedMods = (state.mods || [])
    .filter(item => item.installed)
    .map(item => item.profileId);

  (state.mods || []).forEach(item => {
    const mod = upsertCatalogMod(item, state);
    ensureCatalogModCard(mod);
  });

  if (state.download?.busy && state.download.profileId) {
    const profileId = state.download.profileId;
    downloadMetrics.set(profileId, {
      ...downloadMetrics.get(profileId),
      ...state.download
    });
    setHomeDownloadProgress(profileId, Number(state.download.fraction || 0), true);
  }

  syncInstalledModCards();
  syncActiveModSourceLink();
  syncNativeSystemStatus();
  syncModHubAttention();

  if (!modalBackdrop.hidden && modalTitle.textContent === "Mod Hub") {
    renderModLibrary();
  }
}

function syncNativeSystemStatus() {
  if (!nativeState) return;
  const engine = document.querySelector("#systemEngine");
  const launcher = document.querySelector("#systemLauncher");
  const gameData = document.querySelector("#systemGameData");
  const profiles = document.querySelector("#systemProfiles");
  const footerBuild = document.querySelector("#footerBuild");

  if (engine) engine.textContent = nativeState.engineVersion || "unknown";
  if (launcher) launcher.textContent =
    `${nativeState.launcherVersion || "unknown"} · web ${nativeState.launcherWebVersion || "bundled"}`;
  const onlineInstalled = Boolean(nativeState.online?.installed);
  if (gameData) {
    gameData.textContent = onlineInstalled ? "Ready" : "Не установлено";
    gameData.classList.toggle("good", onlineInstalled);
  }
  if (profiles) {
    const installedCount = (onlineInstalled ? 1 : 0) + (nativeState.mods || []).filter(item => item.installed).length;
    profiles.textContent = `${installedCount} ready`;
  }
  if (footerBuild) footerBuild.textContent = `BUILD ${nativeState.build || "unknown"}`;

  const currentProfileId = nativeProfileIdForCard();
  const profile = nativeProfileState(currentProfileId);
  const installed = Boolean(profile?.installed);
  const updateAvailable = Boolean(profile?.updateAvailable);
  statusLabel.textContent = installed ? (updateAvailable ? "UPDATE" : "READY") : "НЕ УСТАНОВЛЕНО";
  statusLabel.classList.toggle("status-text--warning", !installed || updateAvailable);
  statusLabel.classList.toggle("status-text--ready", installed && !updateAvailable);
  playLabel.textContent = !installed ? "INSTALL" : (updateAvailable ? "UPDATE" : "PLAY");
}

async function syncNativeState() {
  if (!hasNativeBridge) return;
  try {
    applyNativeState(await nativeRequest("getState"));
  } catch (error) {
    showToast(error.message || "Не удалось получить состояние лаунчера");
  }
}

function updateNativeProgress(payload) {
  const profileId = payload.profileId;
  if (!profileId) return;
  const metrics = {
    ...downloadMetrics.get(profileId),
    ...payload,
    busy: true
  };
  downloadMetrics.set(profileId, metrics);
  setHomeDownloadProgress(profileId, Number(metrics.fraction || 0), true);
  updateDownloadPanel(profileId);
}

function handleNativeEvent(name, payload) {
  if (name === "stateChanged") {
    applyNativeState(payload);
    return;
  }
  if (name === "downloadProgress") {
    updateNativeProgress(payload);
    return;
  }
  if (name === "installComplete") {
    const title = modCatalog.find(item => item.id === payload.profileId)?.title ||
      (payload.profileId === "online" ? "Zero Hour + Online" : payload.profileId);
    downloadMetrics.delete(payload.profileId);
    finishHomeDownload(payload.profileId, "complete");
    triggerHaptic("success");
    showToast(`${title} установлено`);
    syncNativeState().then(() => {
      const installedCard = cardForProfileId(payload.profileId);
      if (installedCard) setActiveCard(installedCard);
    });
    return;
  }
  if (name === "downloadCancelled") {
    downloadMetrics.delete(payload.profileId);
    finishHomeDownload(payload.profileId, "cancel");
    showToast("Загрузка отменена");
    syncNativeState();
    return;
  }
  if (name === "installError") {
    downloadMetrics.delete(payload.profileId);
    finishHomeDownload(payload.profileId, "error");
    showToast(payload.error || "Установка не удалась");
    syncNativeState();
  }
}

let cards = [...document.querySelectorAll(".mode-card")];
const defaultProfileOrder = cards.map(card => card.dataset.id).filter(Boolean);
const hero = document.querySelector(".hero");
const modeTitle = document.querySelector("#modeTitle");
const modeDescription = document.querySelector("#modeDescription");
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
const modHubBadge = addModCard?.querySelector(".mod-hub-badge") || null;
const audioToggle = document.querySelector("#audioToggle");
const profileOrderToggle = document.querySelector("#profileOrderToggle");

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
let profileOrderEditing = false;
let profileDrag = null;
const PROFILE_ORDER_KEY = "generals-x-profile-order-v1";
const MOD_HUB_SEEN_KEY = "generals-x-mod-hub-seen-v1";
const LEGACY_MOD_IDS = new Set(["enhanced", "contra-x", "contra-007"]);
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
  if (!hasNativeBridge) return;
  window.GeneralsXNative.request("haptic", { style }, 1200).catch(() => {});
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
  audioToggle.setAttribute("aria-label", uiSoundEnabled ? "Mute interface sounds" : "Enable interface sounds");
  audioToggle.title = uiSoundEnabled ? "Mute interface sounds" : "Enable interface sounds";
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
    description: "Обновлённый профиль Zero Hour со своими визуальными настройками, интерфейсом и ИИ.",
    author: "Acoustic Alpha",
    moddbUrl: "https://www.moddb.com/mods/cc-generals-zero-hour-enhanced"
  },
  {
    id: "contra-x",
    title: "Contra X",
    description: "Contra X Beta 2 + Патч 1 с отдельными настройками мода.",
    author: "Команда Contra Mod",
    moddbUrl: "https://www.moddb.com/mods/contra"
  },
  {
    id: "contra-007",
    title: "Contra 007",
    description: "Классическая Contra 0.07 с официальными патчами Fixed AI и Map Fix.",
    author: "Команда Contra Mod",
    moddbUrl: "https://www.moddb.com/mods/contra/downloads/contra-007"
  },
  {
    id: "contra-009",
    title: "Contra 009",
    description: "Contra 009 Final с патчами 1–3 и официальным Hotfix 1–4 для патча 3.",
    author: "Команда Contra Mod",
    moddbUrl: "https://www.moddb.com/mods/contra"
  }
];

function upsertCatalogMod(item, state = nativeState) {
  const profileId = item?.profileId || "";
  if (!profileId) return null;

  let mod = modCatalog.find(candidate => candidate.id === profileId);
  if (!mod) {
    mod = {
      id: profileId,
      title: item.name || profileId,
      description: item.description || "",
      author: item.author || "Автор мода",
      moddbUrl: item.sourceURL || ""
    };
    modCatalog.push(mod);
  }

  mod.title = item.name || mod.title || profileId;
  mod.description = item.description || mod.description || "";
  mod.version = item.version || "";
  mod.installedVersion = item.installedVersion || "";
  mod.updateAvailable = Boolean(item.updateAvailable);
  mod.packageBytes = Number(item.packageBytes || 0);
  mod.releaseNotes = item.releaseNotes || "";
  mod.channel = item.channel || state?.channel || "stable";
  mod.requestedChannel = item.requestedChannel || state?.channel || "stable";
  mod.fallbackChannel = item.fallbackChannel || "";
  if (item.sourceURL) mod.moddbUrl = item.sourceURL;
  if (item.author) mod.author = item.author;
  return mod;
}

function ensureCatalogModCard(mod) {
  if (!mod) return null;
  let card = cardForProfileId(mod.id);
  if (card) {
    card.dataset.title = mod.title || mod.id;
    card.dataset.description = mod.description || "";
    const strong = card.querySelector("strong");
    if (strong) strong.textContent = mod.title || mod.id;
    return card;
  }
  if (!modesRail) return null;

  card = document.createElement("button");
  card.className = "mode-card";
  card.type = "button";
  card.hidden = true;
  card.dataset.id = mod.id;
  card.dataset.title = mod.title || mod.id;
  card.dataset.description = mod.description || "";
  card.dataset.profile = String(mod.id).toUpperCase();
  card.dataset.status = "READY";
  card.dataset.play = String(mod.title || mod.id).toUpperCase();
  card.innerHTML = `
    <span class="mode-card__content">
      <strong></strong>
      <small></small>
    </span>
  `;
  card.querySelector("strong").textContent = mod.title || mod.id;
  card.querySelector("small").textContent = mod.installedVersion || mod.version || "Installed";
  card.addEventListener("click", () => {
    if (!profileOrderEditing) setActiveCard(card);
  });

  modesRail.append(card);
  cards.push(card);
  return card;
}

function loadInstalledMods() {
  try {
    const saved = JSON.parse(localStorage.getItem("generals-x-launcher-demo-installed-mods") || "[]");
    return Array.isArray(saved) ? saved.filter(id => modCatalog.some(mod => mod.id === id)) : [];
  } catch {
    return [];
  }
}

let installedMods = loadInstalledMods();

function saveInstalledMods() {
  try {
    localStorage.setItem("generals-x-launcher-demo-installed-mods", JSON.stringify(installedMods));
  } catch {
    // Demo still works without persistent browser storage.
  }
}

function isModInstalled(modId) {
  return installedMods.includes(modId);
}

function loadJSONStorage(key, fallback) {
  try {
    const value = JSON.parse(localStorage.getItem(key) || "null");
    return value ?? fallback;
  } catch {
    return fallback;
  }
}

function savedProfileOrder() {
  const value = loadJSONStorage(PROFILE_ORDER_KEY, []);
  return Array.isArray(value) && value.length ? value : defaultProfileOrder;
}

function refreshCardsFromDOM() {
  if (modesRail) cards = [...modesRail.querySelectorAll(".mode-card")];
  return cards;
}

function saveProfileOrder() {
  if (!modesRail) return;
  const order = refreshCardsFromDOM()
    .filter(card => !card.hidden)
    .map(card => card.dataset.id)
    .filter(Boolean);
  try { localStorage.setItem(PROFILE_ORDER_KEY, JSON.stringify(order)); } catch {}
}

function currentPriorityDownloadId() {
  if (nativeState?.download?.busy && nativeState.download.profileId) return nativeState.download.profileId;
  for (const [profileId, state] of homeDownloadState.entries()) {
    if (state?.active) return profileId;
  }
  return "";
}

function applyProfileOrder(priorityProfileId = currentPriorityDownloadId()) {
  if (!modesRail || profileOrderEditing) return;

  const saved = savedProfileOrder();
  const rank = new Map(saved.map((id, index) => [id, index]));
  const current = [...refreshCardsFromDOM()];
  const originalRank = new Map(current.map((card, index) => [card, index]));
  const ordered = current.sort((a, b) => {
    const ar = rank.has(a.dataset.id) ? rank.get(a.dataset.id) : Number.MAX_SAFE_INTEGER;
    const br = rank.has(b.dataset.id) ? rank.get(b.dataset.id) : Number.MAX_SAFE_INTEGER;
    return ar === br ? originalRank.get(a) - originalRank.get(b) : ar - br;
  });

  ordered.forEach(card => modesRail.append(card));

  const priority = priorityProfileId ? cardForProfileId(priorityProfileId) : null;
  if (priority && !priority.hidden) {
    const first = refreshCardsFromDOM().find(card => !card.hidden && card !== priority);
    if (first) modesRail.insertBefore(priority, first);
    else modesRail.append(priority);
  }
  refreshCardsFromDOM();
  updateModesOverflow();
}

function loadModHubSeen() {
  const value = loadJSONStorage(MOD_HUB_SEEN_KEY, {});
  return value && typeof value === "object" && !Array.isArray(value) ? value : {};
}

function syncModHubAttention() {
  if (!addModCard || !modHubBadge || !nativeState) return;
  const seen = loadModHubSeen();
  const needsAttention = (nativeState.mods || []).some(item => {
    if (item.installed && item.updateAvailable) return true;
    if (item.installed || !item.version) return false;
    if (!seen[item.profileId] && LEGACY_MOD_IDS.has(item.profileId)) return false;
    return seen[item.profileId] !== item.version;
  });

  addModCard.classList.toggle("has-attention", needsAttention);
  modHubBadge.hidden = !needsAttention;
  const label = needsAttention ? "Центр модификаций — доступны новые моды или обновления" : "Mod Hub";
  addModCard.setAttribute("aria-label", label);
  addModCard.title = label;
}

function markModHubSeen() {
  if (!nativeState) return;
  const seen = loadModHubSeen();
  (nativeState.mods || []).forEach(item => {
    if (item.profileId && item.version) seen[item.profileId] = item.version;
  });
  try { localStorage.setItem(MOD_HUB_SEEN_KEY, JSON.stringify(seen)); } catch {}
  syncModHubAttention();
}

function cardForProfileId(profileId) {
  const cardId = profileId === "online" ? "zero-hour-online" : profileId;
  return cards.find(card => card.dataset.id === cardId) || null;
}

function ensureHomeDownloadPercent(card) {
  if (!card) return null;
  let indicator = card.querySelector(".mode-card__download-percent");
  if (!indicator) {
    indicator = document.createElement("span");
    indicator.className = "mode-card__download-percent";
    indicator.setAttribute("aria-hidden", "true");
    card.append(indicator);
  }

  let border = card.querySelector(".mode-card__download-border");
  if (!border) {
    border = document.createElement("span");
    border.className = "mode-card__download-border";
    border.setAttribute("aria-hidden", "true");
    border.innerHTML = "<span></span>";
    card.append(border);
  }
  return indicator;
}

function setHomeDownloadProgress(profileId, fraction = 0, active = true) {
  const value = Math.max(0, Math.min(1, Number(fraction || 0)));
  homeDownloadState.set(profileId, { active, fraction: value });
  const card = cardForProfileId(profileId);
  if (!card) return;

  const pendingInstall = profileId === "online"
    ? !Boolean(nativeState?.online?.installed)
    : !isModInstalled(profileId);
  const indicator = ensureHomeDownloadPercent(card);

  card.hidden = false;
  card.classList.toggle("is-downloading", active);
  card.classList.toggle("is-download-pending", active && pendingInstall);
  card.classList.remove("is-download-error", "is-download-complete");

  if (indicator) {
    indicator.textContent = active ? `${Math.round(value * 100)}%` : "";
  }
  if (active) applyProfileOrder(profileId);
  updateModesOverflow();
}

function finishHomeDownload(profileId, outcome) {
  const card = cardForProfileId(profileId);
  homeDownloadState.delete(profileId);
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
  syncInstalledModCards();
}

function updateModesOverflow() {
  if (!modesRail) return;
  window.requestAnimationFrame(() => {
    const overflowing = modesRail.scrollWidth > modesRail.clientWidth + 2;
    modesRail.classList.toggle("is-overflowing", overflowing);
  });
}

function syncModeCardVersions() {
  const baseCard = cards.find(item => item.dataset.id === "zero-hour-online");
  const baseVersion = nativeState?.online?.installedVersion || nativeState?.online?.version || "1.04";
  const baseSmall = baseCard?.querySelector("small");
  if (baseSmall) baseSmall.textContent = `${baseVersion} · Сетевая игра`;

  modCatalog.forEach(mod => {
    const card = cards.find(item => item.dataset.id === mod.id);
    const small = card?.querySelector("small");
    if (!small) return;
    small.textContent = mod.installedVersion || mod.version || (mod.id === "contra-x" ? "Beta 2 · Патч 1" : "Installed");
  });
}

function syncInstalledModCards() {
  const hasInstalledMods = installedMods.length > 0;
  const baseCard = cards.find(item => item.dataset.id === "zero-hour-online");
  if (baseCard) baseCard.hidden = !hasInstalledMods;

  modCatalog.forEach(mod => {
    const card = cards.find(item => item.dataset.id === mod.id);
    const downloading = Boolean(homeDownloadState.get(mod.id)?.active);
    if (card) card.hidden = !isModInstalled(mod.id) && !downloading;
  });

  syncModeCardVersions();
  applyProfileOrder();
  updateModesOverflow();
}

function syncActiveModSourceLink() {
  if (!modSourceLink) return;

  const mod = modCatalog.find(item => item.id === activeCard?.dataset.id);
  const shouldShow = Boolean(mod && isModInstalled(mod.id));

  modSourceLink.hidden = !shouldShow;

  if (!shouldShow) {
    modSourceLink.removeAttribute("href");
    modSourceLink.removeAttribute("title");
    return;
  }

  modSourceLink.href = mod.moddbUrl;
  modSourceLink.title = `Оригинальный мод на ModDB — ${mod.author}`;
}

const настройкиDefaults = {
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
    textureQuality: "High",
    particles: "Medium",
    textureFilter: "Anisotropic",
    anisotropy: "8x",
    msaa: "Off",
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
    textureResolution: "High",
    uiQuality: "FHD",
    infantryIconScale: "100%",
    cameos: "HD",
    aiScripts: "Default"
  },
  contra: {
    controlBar: "Contra",
    cameos: "Standard",
    music: "Standard",
    voices: "English",
    hotkeys: "Original",
    hotkeyLanguage: "English",
    portraits: "Standard",
    fogEffects: false,
    waterEffects: true,
    extraBuildingProps: true
  }
};

function cloneSettingsDefaults() {
  return JSON.parse(JSON.stringify(settingsDefaults));
}

function loadDemoSettings() {
  try {
    const saved = localStorage.getItem("generals-x-launcher-demo-settings");
    if (!saved) return cloneSettingsDefaults();
    const parsed = JSON.parse(saved);
    return {
      game: { ...settingsDefaults.game, ...(parsed.game || {}) },
      enhanced: { ...settingsDefaults.enhanced, ...(parsed.enhanced || {}) },
      contra: { ...settingsDefaults.contra, ...(parsed.contra || {}) }
    };
  } catch {
    return cloneSettingsDefaults();
  }
}

let настройкиState = loadDemoSettings();

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
    modeDescription.textContent = card.dataset.description;
    profileLabel.textContent = card.dataset.profile;
    statusLabel.textContent = card.dataset.status;
    playLabel.textContent = "PLAY";

    const experimental = card.dataset.status === "EXPERIMENTAL";
    statusLabel.classList.toggle("status-text--warning", experimental);
    statusLabel.classList.toggle("status-text--ready", !experimental);

    syncActiveModSourceLink();
    if (hasNativeBridge) syncNativeSystemStatus();

    hero.classList.remove("is-switching");
    card.scrollIntoView({ behavior: "smooth", block: "nearest", inline: "nearest" });
  }, 155);
}

cards.forEach(card => {
  card.addEventListener("click", () => {
    if (!profileOrderEditing) setActiveCard(card);
  });
});

playButton.addEventListener("click", async () => {
  const profileId = nativeProfileIdForCard();
  if (!hasNativeBridge) {
    showToast("Демо: запрос запуска для " + activeCard.dataset.title);
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
        setHomeDownloadProgress(profileId, 0, true);
        showToast(`${updateAvailable ? "Updating" : "Downloading"} ${activeCard.dataset.title}…`);
        await nativeRequest("install", { profileId });
        await syncNativeState();
      } else {
        await nativeRequest("chooseFile", { profileId });
        showToast(`Выберите пакет ${activeCard.dataset.title}`);
      }
    } catch (error) {
      downloadMetrics.delete(profileId);
      finishHomeDownload(profileId, "error");
      showToast(error.message || "Установка не удалась");
    }
    return;
  }

  if (profileId !== "online" && !nativeState?.online?.installed) {
    showToast("Сначала установите основные файлы Zero Hour + Сеть");
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

async function openPanel(type) {
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
            ? "Настройки Zero Hour + Сеть"
            : activeCard.dataset.title + " настройки";
    if (hasNativeBridge) {
      try {
        const nativeSettings = await nativeRequest("settingsGet", { profileId });
        const scope = profileId === "enhanced" ? "enhanced" : profileId === "contra-x" ? "contra" : "game";
        настройкиState[scope] = { ...settingsDefaults[scope], ...(nativeSettings?.values || {}) };
      } catch (error) {
        showToast(error.message || "Unable to load настройки");
      }
    }
    renderSettings(profileId);
  } else if (type === "mods") {
    modalEyebrow.textContent = "GENERALS X";
    modalTitle.textContent = "Mod Hub";
    renderModLibrary();
    markModHubSeen();
  } else if (type === "diagnostics") {
    modalEyebrow.textContent = "SYSTEM";
    modalTitle.textContent = "Diagnostics";
    renderDiagnostics();
  } else {
    modalEyebrow.textContent = activeCard.dataset.profile;
    modalTitle.textContent = activeCard.dataset.title;
    modalBody.innerHTML = `
      <div class="setting-section">
        <h3>Profile information</h3>
        <div class="setting-row"><span>Status</span><strong>${activeCard.dataset.status}</strong></div>
        <div class="setting-row"><span>Target</span><strong>iPad / Mac</strong></div>
        <div class="setting-row"><span>Launcher mode</span><strong>Web UI · native bridge</strong></div>
      </div>
      <div class="setting-section">
        <h3>Description</h3>
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

function currentDownloadMetrics(profileId) {
  if (downloadMetrics.has(profileId)) return downloadMetrics.get(profileId);
  if (nativeState?.download?.busy && nativeState.download.profileId === profileId) {
    return nativeState.download;
  }
  return null;
}

function downloadStatusText(profileId) {
  const metrics = currentDownloadMetrics(profileId);
  if (!metrics) return "";
  const parts = [];
  const percent = Math.round(Math.max(0, Math.min(1, Number(metrics.fraction || 0))) * 100);
  parts.push(metrics.paused ? `Paused · ${percent}%` : `${percent}%`);
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

function modVersionSummary(mod) {
  const nativeMod = nativeModState(mod.id);
  const installed = isModInstalled(mod.id);
  const current = nativeMod?.installedVersion || mod.installedVersion || "";
  const available = nativeMod?.version || mod.version || "";
  const updateAvailable = Boolean(nativeMod?.updateAvailable || mod.updateAvailable) &&
    Boolean(available) && available !== current;

  if (!installed) {
    return `
      <div class="mod-version-summary">
        <span><em>Version</em><strong>${available || "Unknown"}</strong></span>
        ${mod.packageBytes ? `<span><em>Download</em><strong>${humanSize(mod.packageBytes)}</strong></span>` : ""}
      </div>`;
  }

  return `
    <div class="mod-version-summary">
      <span><em>Current</em><strong>${current || "Unknown"}</strong></span>
      ${updateAvailable ? `<span class="has-update"><em>New</em><strong>${available}</strong></span>` : ""}
    </div>`;
}

function modInstallActions(mod) {
  const nativeMod = nativeModState(mod.id);
  const installed = isModInstalled(mod.id);
  const download = currentDownloadMetrics(mod.id);
  const activeDownload = Boolean(download?.busy);
  const busy = Boolean(nativeState?.download?.busy);
  const updateAvailable = Boolean(nativeMod?.updateAvailable || mod.updateAvailable) &&
    Boolean(nativeMod?.version || mod.version) &&
    (nativeMod?.version || mod.version) !== (nativeMod?.installedVersion || mod.installedVersion || "");

  if (activeDownload) return "";

  if (installed) {
    return `
      ${updateAvailable ? `
        <button type="button" class="mod-install-button mod-install-button--primary" data-mod-download="${mod.id}" ${busy ? "disabled" : ""}>
          Update
        </button>` : ""}
      <button type="button" class="mod-install-button" data-mod-remove="${mod.id}" ${busy ? "disabled" : ""}>Remove</button>
    `;
  }

  return `
    <button type="button" class="mod-install-button mod-install-button--primary" data-mod-download="${mod.id}" ${busy ? "disabled" : ""}>
      <svg class="lucide lucide-cloud-download" viewBox="0 0 24 24" aria-hidden="true">
        <path d="M12 13v8M8 17l4 4 4-4"/>
        <path d="M20.39 18.39A5 5 0 0 0 18 9h-1.26A8 8 0 1 0 3 16.3"/>
      </svg>
      Download
    </button>
    <button type="button" class="mod-install-button" data-mod-file="${mod.id}" ${busy ? "disabled" : ""}>
      <svg class="lucide lucide-file-up" viewBox="0 0 24 24" aria-hidden="true">
        <path d="M14.5 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7.5L14.5 2z"/>
        <polyline points="14 2 14 8 20 8"/>
        <path d="M12 18v-6M9 15l3-3 3 3"/>
      </svg>
      Choose File
    </button>
    <input class="mod-file-input" type="file" data-mod-file-input="${mod.id}">
  `;
}

function modDownloadPanel(mod) {
  const metrics = currentDownloadMetrics(mod.id);
  if (!metrics?.busy) return "";
  const fraction = Math.max(0, Math.min(1, Number(metrics.fraction || 0)));
  return `
    <div class="mod-download-panel" data-mod-progress="${mod.id}">
      <div class="mod-download-track" aria-label="Ход загрузки">
        <span style="width:${Math.round(fraction * 100)}%"></span>
      </div>
      <div class="mod-download-status" data-download-status="${mod.id}">${downloadStatusText(mod.id)}</div>
      <div class="mod-download-controls">
        <button type="button" class="mod-download-control" data-download-toggle="${mod.id}">
          ${metrics.paused ? "Resume" : "Pause"}
        </button>
        <button type="button" class="mod-download-control mod-download-control--cancel" data-download-cancel="${mod.id}">Cancel</button>
      </div>
    </div>
  `;
}

function updateDownloadPanel(profileId) {
  const metrics = currentDownloadMetrics(profileId);
  const panel = document.querySelector(`[data-mod-progress="${profileId}"]`);
  if (!panel || !metrics) {
    if (!modalBackdrop.hidden && modalTitle.textContent === "Mod Hub") renderModLibrary();
    return;
  }
  const bar = panel.querySelector(".mod-download-track span");
  const status = panel.querySelector(`[data-download-status="${profileId}"]`);
  const toggle = panel.querySelector(`[data-download-toggle="${profileId}"]`);
  const fraction = Math.max(0, Math.min(1, Number(metrics.fraction || 0)));
  if (bar) bar.style.width = `${Math.round(fraction * 100)}%`;
  if (status) status.textContent = downloadStatusText(profileId);
  if (toggle) toggle.textContent = metrics.paused ? "Resume" : "Pause";
}

function renderModLibrary() {
  modalBody.innerHTML = `
    <div class="mod-library">
      <div class="mod-library__toolbar">
        <div class="segment-control mod-channel-control">
          <button type="button" data-channel="stable" class="${(nativeState?.channel || "stable") === "stable" ? "is-selected" : ""}">Stable</button>
          <button type="button" data-channel="beta" class="${nativeState?.channel === "beta" ? "is-selected" : ""}">Beta</button>
        </div>
        <button type="button" class="diagnostics-action" data-catalog-refresh>Refresh</button>
      </div>
      <p class="mod-library__intro">Install or update profiles from the Generals X catalog. Only one large package is downloaded at a time.</p>
      ${modCatalog.map(mod => `
        <div class="mod-library-card" data-mod-card="${mod.id}">
          <div class="mod-library-card__main">
            <div class="mod-library-card__copy">
              <strong>${mod.title}</strong>
              <span>${mod.description}</span>
              ${modVersionSummary(mod)}
              ${mod.fallbackChannel ? `<span class="mod-channel-note">${mod.fallbackChannel.toUpperCase()} package fallback</span>` : ""}
              ${mod.moddbUrl ? `
                <a class="mod-author-link" href="${mod.moddbUrl}" target="_blank" rel="noopener noreferrer">
                  <svg class="lucide lucide-external-link" viewBox="0 0 24 24" aria-hidden="true">
                    <path d="M15 3h6v6"/>
                    <path d="M10 14 21 3"/>
                    <path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/>
                  </svg>
                  Original mod by ${mod.author || "Автор мода"} · ModDB
                </a>` : ""}
            </div>
            <div class="mod-library-card__actions">
              ${modInstallActions(mod)}
            </div>
          </div>
          ${modDownloadPanel(mod)}
        </div>
      `).join("")}
    </div>
  `;

  modalBody.querySelectorAll("[data-mod-download]").forEach(button => {
    button.addEventListener("click", () => {
      if (hasNativeBridge) installNativeMod(button.dataset.modDownload, button);
      else simulateCloudInstall(button.dataset.modDownload, button);
    });
  });

  modalBody.querySelectorAll("[data-mod-remove]").forEach(button => {
    button.addEventListener("click", async () => {
      try {
        const state = await nativeRequest("remove", { profileId: button.dataset.modRemove });
        applyNativeState(state);
        showToast("Мод удалён");
      } catch (error) {
        showToast(error.message || "Не удалось удалить мод");
      }
    });
  });

  modalBody.querySelectorAll("[data-download-toggle]").forEach(button => {
    button.addEventListener("click", async () => {
      const profileId = button.dataset.downloadToggle;
      const metrics = currentDownloadMetrics(profileId);
      if (!metrics) return;
      try {
        const action = metrics.paused ? "resumeDownload" : "pauseDownload";
        applyNativeState(await nativeRequest(action, { profileId }));
        const latest = nativeState?.download;
        if (latest?.profileId === profileId) downloadMetrics.set(profileId, latest);
        updateDownloadPanel(profileId);
        showToast(metrics.paused ? "Загрузка продолжена" : "Загрузка приостановлена");
      } catch (error) {
        showToast(error.message || "Не удалось изменить состояние загрузки");
      }
    });
  });

  modalBody.querySelectorAll("[data-download-cancel]").forEach(button => {
    button.addEventListener("click", async () => {
      const profileId = button.dataset.downloadCancel;
      try {
        await nativeRequest("cancelDownload", { profileId });
        button.disabled = true;
        showToast("Отмена загрузки…");
      } catch (error) {
        showToast(error.message || "Не удалось отменить загрузку");
      }
    });
  });

  modalBody.querySelectorAll("[data-channel]").forEach(button => {
    button.addEventListener("click", async () => {
      if (!hasNativeBridge) return;
      try {
        applyNativeState(await nativeRequest("setChannel", { channel: button.dataset.channel }));
        showToast(`Канал ${button.dataset.channel.toUpperCase()} активен`);
      } catch (error) {
        showToast(error.message || "Не удалось сменить канал");
      }
    });
  });

  modalBody.querySelector("[data-catalog-refresh]")?.addEventListener("click", async () => {
    if (!hasNativeBridge) return;
    try {
      applyNativeState(await nativeRequest("refreshCatalog"));
      showToast("Каталог обновлён");
    } catch (error) {
      showToast(error.message || "Не удалось обновить каталог");
    }
  });

  modalBody.querySelectorAll("[data-mod-file]").forEach(button => {
    button.addEventListener("click", () => {
      if (hasNativeBridge) {
        nativeRequest("chooseFile", { profileId: button.dataset.modFile })
          .catch(error => showToast(error.message || "Не удалось открыть выбор файлов"));
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


async function installNativeMod(modId, button) {
  const mod = modCatalog.find(item => item.id === modId);
  if (!mod) return;

  button.disabled = true;
  downloadMetrics.set(modId, { busy: true, profileId: modId, paused: false, received: 0, total: mod.packageBytes || 0, fraction: 0 });
  setHomeDownloadProgress(modId, 0, true);
  const fallbackNote = mod.fallbackChannel ? ` · используется пакет ${mod.fallbackChannel.toUpperCase()}` : "";
  showToast(`Загрузка ${mod.title}${fallbackNote}…`);
  try {
    await nativeRequest("install", { profileId: modId });
    await syncNativeState();
  } catch (error) {
    downloadMetrics.delete(modId);
    finishHomeDownload(modId, "error");
    button.disabled = false;
    showToast(error.message || "Загрузка не удалась");
  }
}

function simulateCloudInstall(modId, button) {
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

  if (!isModInstalled(modId)) {
    installedMods.push(modId);
    saveInstalledMods();
  }

  syncInstalledModCards();

  const card = cards.find(item => item.dataset.id === modId);
  if (card) setActiveCard(card);

  showToast(`${mod.title} установлено${source === "file" ? " from file" : ""}`);
  window.setTimeout(closePanel, 220);
}

function diagnosticsReport() {
  return `APP
Project: Generals X
Bundle: demo
Platform: Local browser
Device: ${navigator.platform || "Unknown"}

BUILD
Launcher: demo-01
Launcher run: local
Engine: 0.1.0
Base shell run: local

CONTENT
GameData: Installed
Zero Hour + Online: Installed
Enhanced: ${isModInstalled("enhanced") ? "Installed" : "Не установлено"}
Contra X: ${isModInstalled("contra") ? "Installed" : "Не установлено"}

FILES
iPad настройки: Present
Настройки Enhanced: ${isModInstalled("enhanced") ? "Present" : "n/a"}
Contra настройки: ${isModInstalled("contra") ? "Present" : "n/a"}
Current session: Yes
Session logs: 1/10`;
}

function renderDiagnostics() {
  modalBody.innerHTML = `
    <p class="diagnostics-note">Build, installed content and crash logs. A copy is saved automatically to Files > On My iPad > Generals ZH > Diagnostics.</p>
    <div class="diagnostic-block" id="diagnosticReport">${diagnosticsReport()}</div>
    <div class="diagnostics-actions">
      <button type="button" class="diagnostics-action" data-diagnostics-refresh>Refresh</button>
      <button type="button" class="diagnostics-action" data-diagnostics-export>Сохранить to Files</button>
      <button type="button" class="diagnostics-action" data-diagnostics-share>Share report + logs</button>
      <button type="button" class="diagnostics-action diagnostics-action--danger" data-diagnostics-clear>Clear logs</button>
    </div>
  `;

  const refreshDiagnostics = async () => {
    if (!hasNativeBridge) {
      modalBody.querySelector("#diagnosticReport").textContent = diagnosticsReport();
      showToast("Диагностика обновлена");
      return;
    }
    try {
      const result = await nativeRequest("diagnostics");
      nativeDiagnosticsText = result?.report || "";
      modalBody.querySelector("#diagnosticReport").textContent = nativeDiagnosticsText || "Диагностические данные недоступны.";
      if (result?.exportPath) showToast(`Диагностика сохранена: ${result.exportPath}`);
    } catch (error) {
      modalBody.querySelector("#diagnosticReport").textContent = error.message || "Не удалось получить диагностику";
    }
  };

  modalBody.querySelector("[data-diagnostics-refresh]").addEventListener("click", refreshDiagnostics);
  if (hasNativeBridge) refreshDiagnostics();

  modalBody.querySelector("[data-diagnostics-export]").addEventListener("click", async () => {
    if (!hasNativeBridge) {
      showToast("Нативный мост недоступен");
      return;
    }
    showToast("Сохранение диагностики в «Файлы»…");
    try {
      const result = await nativeRequest("exportDiagnostics");
      showToast(`Сохранено файлов: ${result?.fileCount || 0} · ${result?.path || "Diagnostics"}`);
    } catch (error) {
      showToast(error.message || "Сохранение не удалось");
    }
  });

  modalBody.querySelector("[data-diagnostics-share]").addEventListener("click", async () => {
    if (hasNativeBridge) {
      showToast("Открытие меню «Поделиться»…");
      try {
        await nativeRequest("shareDiagnostics");
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
        showToast("Общий доступ недоступен в этом браузере");
      }
    } catch {
      // User cancellation is not an error for this demo.
    }
  });

  modalBody.querySelector("[data-diagnostics-clear]").addEventListener("click", async () => {
    if (hasNativeBridge) {
      try {
        await nativeRequest("clearDiagnostics");
        showToast("Окно очистки открыто");
      } catch (error) {
        showToast(error.message || "Не удалось очистить данные");
      }
    } else {
      showToast("Журнал демо очищен");
    }
  });
}

function segmentControl(scope, key, choices) {
  const value = настройкиState[scope][key];
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
  const value = настройкиState[scope][key];
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

function renderGameSettings() {
  return `
    <div class="setting-section">
      <h3>Graphics</h3>
      ${settingRow("3D-тени", toggleControl("game", "shadow3D"))}
      ${settingRow("2D-тени", toggleControl("game", "shadow2D"))}
      ${settingRow("Тени облаков", toggleControl("game", "cloudShadows"))}
      ${settingRow("Освещение поверхности", toggleControl("game", "groundLighting"))}
      ${settingRow("Сглаженные границы воды", toggleControl("game", "softWater"))}
      ${settingRow("Юниты за зданиями", toggleControl("game", "buildingOcclusion"))}
      ${settingRow("Мелкие объекты / деревья", toggleControl("game", "showProps"))}
      ${settingRow("Дополнительные анимации", toggleControl("game", "extraAnimations"))}
      ${settingRow("Динамический LOD", toggleControl("game", "dynamicLOD"))}
      ${settingRow("Эффекты нагрева", toggleControl("game", "heatEffects"))}
      ${settingRow("Качество текстур", segmentControl("game", "textureQuality", ["High", "Medium", "Low"]))}
      ${settingRow("Particles", segmentControl("game", "particles", ["Low", "Medium", "High"]))}
      ${settingRow("Фильтрация текстур", segmentControl("game", "textureFilter", ["Bilinear", "Trilinear", "Anisotropic"]))}
      ${settingRow("Anisotropy", segmentControl("game", "anisotropy", ["2x", "4x", "8x", "16x"]))}
      ${settingRow("MSAA", segmentControl("game", "msaa", ["Off", "2x", "4x", "8x"]))}
    </div>

    <div class="setting-section">
      <h3>Camera / Performance</h3>
      ${settingRow("Максимальная высота камеры", rangeControl("game", "maxCamera", 300, 800, 10))}
      ${settingRow("Минимальная высота камеры", rangeControl("game", "minCamera", 40, 150, 5))}
      ${settingRow("Наклон камеры", rangeControl("game", "cameraPitch", 20, 60, 1, "°"))}
      ${settingRow("Ограничивать максимальную высоту камеры", toggleControl("game", "enforceMax"))}
      ${settingRow("Скорость прокрутки клавиатурой / у края экрана", rangeControl("game", "scrollSpeed", 0.5, 2, 0.1, "×"))}
      ${settingRow("Дальность прорисовки ландшафта", rangeControl("game", "drawDistance", 0.5, 2, 0.05, "×"))}
      ${settingRow("Ограничение FPS", toggleControl("game", "fpsLimit"))}
      ${settingRow("Кадров в секунду", rangeControl("game", "fps", 30, 120, 5, " FPS"))}
    </div>
  `;
}

function renderEnhancedSettings() {
  return `
    <div class="setting-section">
      <h3>Enhanced</h3>
      ${settingRow("Текстуры фракций", segmentControl("enhanced", "textureResolution", ["Vanilla", "High"]))}
      ${settingRow("Качество интерфейса", segmentControl("enhanced", "uiQuality", ["HD", "FHD", "QHD"]))}
      ${settingRow("Иконки пехоты", segmentControl("enhanced", "infantryIconScale", ["100%", "75%", "50%"]))}
      ${settingRow("Cameos", segmentControl("enhanced", "cameos", ["SD", "HD"]))}
      ${settingRow("Скрипты ИИ", segmentControl("enhanced", "aiScripts", ["Default", "Restrained", "Skynet"]))}
    </div>
  `;
}

function renderContraSettings() {
  return `
    <div class="setting-section">
      <h3>Contra X</h3>
      ${settingRow("Панель управления", segmentControl("contra", "controlBar", ["Contra", "Pro", "Standard"]))}
      ${settingRow("Качество иконок / камео", segmentControl("contra", "cameos", ["Standard", "HD"]))}
      ${settingRow("Music", segmentControl("contra", "music", ["Standard", "Enhanced", "The Score"]))}
      ${settingRow("Голоса юнитов", segmentControl("contra", "voices", ["English", "Native"]))}
      ${settingRow("Hotkeys", segmentControl("contra", "hotkeys", ["Original", "Leikeze"]))}
      ${settingRow("Язык горячих клавиш", segmentControl("contra", "hotkeyLanguage", ["English", "Russian"]))}
      ${settingRow("Портреты генералов", segmentControl("contra", "portraits", ["Standard", "Funny"]))}
      ${settingRow("Эффекты тумана", toggleControl("contra", "fogEffects"))}
      ${settingRow("Эффекты воды", toggleControl("contra", "waterEffects"))}
      ${settingRow("Дополнительные объекты зданий", toggleControl("contra", "extraBuildingProps"))}
    </div>
  `;
}

function renderSettings(profileId = "zero-hour-online") {
  const scope =
    profileId === "enhanced"
      ? "enhanced"
      : profileId === "contra-x"
        ? "contra"
        : "game";

  const content =
    scope === "enhanced"
      ? renderEnhancedSettings()
      : scope === "contra"
        ? renderContraSettings()
        : renderGameSettings();

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
      настройкиState[parent.dataset.scope][parent.dataset.key] = button.dataset.value;
      parent.querySelectorAll("button").forEach(item => item.classList.toggle("is-selected", item === button));
    });
  });

  modalBody.querySelectorAll(".switch-control").forEach(button => {
    button.addEventListener("click", () => {
      const scope = button.dataset.scope;
      const key = button.dataset.key;
      настройкиState[scope][key] = !settingsState[scope][key];
      button.classList.toggle("is-on", настройкиState[scope][key]);
      button.setAttribute("aria-pressed", String(settingsState[scope][key]));
    });
  });

  modalBody.querySelectorAll(".range-control input").forEach(input => {
    input.addEventListener("input", () => {
      const scope = input.dataset.scope;
      const key = input.dataset.key;
      const value = Number(input.value);
      настройкиState[scope][key] = value;
      const suffix = key === "cameraPitch" ? "°" : key === "fps" ? " FPS" : ["scrollSpeed", "drawDistance"].includes(key) ? "×" : "";
      input.parentElement.querySelector("output").textContent = value + suffix;
    });
  });

  modalHeaderActions?.querySelector("[data-settings-save]")?.addEventListener("click", async () => {
    try {
      if (hasNativeBridge) {
        await nativeRequest("settingsСохранить", { profileId, values: настройкиState[scope] });
      } else {
        localStorage.setItem("generals-x-launcher-demo-settings", JSON.stringify(settingsState));
      }
      triggerHaptic("success");
      showToast(`${activeCard.dataset.title} настройки saved`);
    } catch (error) {
      showToast(error.message || "Не удалось сохранить настройки");
    }
  });

  modalHeaderActions?.querySelector("[data-settings-reset]")?.addEventListener("click", () => {
    настройкиState[scope] = { ...settingsDefaults[scope] };
    renderSettings(profileId);
    showToast("Default настройки loaded");
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

function visibleProfileCards() {
  return refreshCardsFromDOM().filter(card => !card.hidden);
}

function ensureProfileOrderGrip(card) {
  let grip = card.querySelector(".profile-order-grip");
  if (!grip) {
    grip = document.createElement("span");
    grip.className = "profile-order-grip";
    grip.setAttribute("aria-hidden", "true");
    grip.innerHTML = "<i></i><i></i><i></i><i></i><i></i><i></i>";
    card.append(grip);
  }
  return grip;
}

function syncProfileOrderGrips() {
  visibleProfileCards().forEach(card => ensureProfileOrderGrip(card));
}

function updateProfileOrderToggle() {
  if (!profileOrderToggle) return;
  profileOrderToggle.classList.toggle("is-active", profileOrderEditing);
  profileOrderToggle.setAttribute("aria-pressed", String(profileOrderEditing));
  profileOrderToggle.setAttribute("aria-label", profileOrderEditing ? "Done arranging profiles" : "Arrange profiles");
  profileOrderToggle.title = profileOrderEditing ? "Done arranging profiles" : "Arrange profiles";
}

function cleanupProfileDrag(commit = true) {
  if (!profileDrag) return;
  const card = profileDrag.card;
  const placeholder = profileDrag.placeholder;
  if (profileDrag.autoScrollFrame) cancelAnimationFrame(profileDrag.autoScrollFrame);

  if (placeholder && placeholder.isConnected) {
    if (commit) modesRail.insertBefore(card, placeholder);
    placeholder.remove();
  }

  card.classList.remove("is-reorder-floating");
  card.style.removeProperty("--reorder-left");
  card.style.removeProperty("--reorder-top");
  card.style.removeProperty("--reorder-width");
  card.style.removeProperty("--reorder-height");
  card.style.removeProperty("--reorder-x");
  profileDrag = null;
  refreshCardsFromDOM();
}

function setProfileOrderEditing(enabled) {
  if (!modesRail) return;
  if (enabled && currentPriorityDownloadId()) {
    showToast("Сначала завершите текущую загрузку");
    return;
  }

  if (enabled && visibleProfileCards().length < 2) {
    showToast("Установите ещё один профиль, чтобы изменить порядок");
    return;
  }

  if (!enabled) cleanupProfileDrag(true);
  profileOrderEditing = Boolean(enabled);
  modesRail.classList.toggle("is-reordering", profileOrderEditing);
  updateProfileOrderToggle();

  if (profileOrderEditing) {
    syncProfileOrderGrips();
    showToast("Перетащите маркер, чтобы изменить порядок профилей");
  } else {
    saveProfileOrder();
    applyProfileOrder();
    showToast("Порядок профилей сохранён");
  }
}

function beginProfileDrag(event) {
  if (!profileOrderEditing || event.button > 0 || !modesRail) return;
  const grip = event.target.closest(".profile-order-grip");
  const card = grip && grip.closest(".mode-card");
  if (!grip || !card || card.hidden) return;

  event.preventDefault();
  const rect = card.getBoundingClientRect();
  const placeholder = document.createElement("div");
  placeholder.className = "profile-order-placeholder";
  placeholder.style.width = rect.width + "px";
  placeholder.style.height = rect.height + "px";
  card.before(placeholder);

  card.classList.add("is-reorder-floating");
  card.style.setProperty("--reorder-left", rect.left + "px");
  card.style.setProperty("--reorder-top", rect.top + "px");
  card.style.setProperty("--reorder-width", rect.width + "px");
  card.style.setProperty("--reorder-height", rect.height + "px");
  card.style.setProperty("--reorder-x", "0px");
  document.body.append(card);

  profileDrag = {
    card,
    placeholder,
    pointerId: event.pointerId,
    startX: event.clientX,
    lastX: event.clientX,
    autoScrollDirection: 0,
    autoScrollFrame: 0
  };

  try { grip.setPointerCapture(event.pointerId); } catch {}
  triggerHaptic("light");
}

function animateReorderSiblings(before) {
  visibleProfileCards().forEach(card => {
    const previousLeft = before.get(card);
    if (previousLeft == null) return;
    const delta = previousLeft - card.getBoundingClientRect().left;
    if (Math.abs(delta) < 1) return;
    card.animate(
      [{ translate: delta + "px 0" }, { translate: "0 0" }],
      { duration: 190, easing: "cubic-bezier(.2,.8,.2,1)" }
    );
  });
}

function reorderPlaceholder(clientX) {
  if (!profileDrag || !modesRail) return;
  const placeholder = profileDrag.placeholder;
  const siblings = [...modesRail.querySelectorAll(".mode-card:not([hidden])")];
  const before = new Map(siblings.map(card => [card, card.getBoundingClientRect().left]));
  const railRect = modesRail.getBoundingClientRect();
  const contentX = clientX - railRect.left + modesRail.scrollLeft;

  let target = null;
  for (const sibling of siblings) {
    const center = sibling.offsetLeft + sibling.offsetWidth / 2;
    if (contentX < center) {
      target = sibling;
      break;
    }
  }

  const previousNext = placeholder.nextElementSibling;
  if (target) {
    if (previousNext !== target) modesRail.insertBefore(placeholder, target);
  } else if (placeholder !== modesRail.lastElementChild) {
    modesRail.append(placeholder);
  }

  if (placeholder.nextElementSibling !== previousNext) animateReorderSiblings(before);
}

function runProfileAutoScroll() {
  if (!profileDrag || !modesRail || !profileDrag.autoScrollDirection) return;
  modesRail.scrollLeft += profileDrag.autoScrollDirection * 7;
  reorderPlaceholder(profileDrag.lastX);
  profileDrag.autoScrollFrame = requestAnimationFrame(runProfileAutoScroll);
}

function updateProfileAutoScroll(clientX) {
  if (!profileDrag || !modesRail) return;
  const railRect = modesRail.getBoundingClientRect();
  const direction = clientX < railRect.left + 48 ? -1 : (clientX > railRect.right - 48 ? 1 : 0);
  if (direction === profileDrag.autoScrollDirection) return;

  profileDrag.autoScrollDirection = direction;
  if (profileDrag.autoScrollFrame) {
    cancelAnimationFrame(profileDrag.autoScrollFrame);
    profileDrag.autoScrollFrame = 0;
  }
  if (direction) profileDrag.autoScrollFrame = requestAnimationFrame(runProfileAutoScroll);
}

function moveProfileDrag(event) {
  if (!profileDrag || event.pointerId !== profileDrag.pointerId || !modesRail) return;
  event.preventDefault();

  profileDrag.lastX = event.clientX;
  const x = event.clientX - profileDrag.startX;
  profileDrag.card.style.setProperty("--reorder-x", x + "px");
  reorderPlaceholder(event.clientX);
  updateProfileAutoScroll(event.clientX);
}

function endProfileDrag(event) {
  if (!profileDrag || event.pointerId !== profileDrag.pointerId) return;
  event.preventDefault();
  cleanupProfileDrag(true);
  saveProfileOrder();
  triggerHaptic("selection");
}

if (profileOrderToggle) {
  updateProfileOrderToggle();
  profileOrderToggle.addEventListener("click", () => setProfileOrderEditing(!profileOrderEditing));
}

if (modesRail) {
  modesRail.addEventListener("pointerdown", beginProfileDrag, { passive: false });
}
document.addEventListener("pointermove", moveProfileDrag, { passive: false });
document.addEventListener("pointerup", endProfileDrag, { passive: false });
document.addEventListener("pointercancel", endProfileDrag, { passive: false });

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
  if (event.key === "Escape") {
    if (profileOrderEditing) setProfileOrderEditing(false);
    else closePanel();
  }

  if (!profileOrderEditing && ["ArrowLeft", "ArrowRight"].includes(event.key)) {
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

syncInstalledModCards();
syncActiveModSourceLink();
updateModesOverflow();

startBackgroundMotion();

if (hasNativeBridge) {
  syncNativeState();
}