const timeline = document.querySelector("#timeline");
const form = document.querySelector("#messageForm");
const input = document.querySelector("#messageInput");
const micButton = document.querySelector("#micButton");
const micStatus = document.querySelector("#micStatus");
const quickActions = document.querySelectorAll(".quick-action");
const photoMedButton = document.querySelector("#photoMedButton");
const medPhotoInput = document.querySelector("#medPhotoInput");

const assistantReplies = [
  "I can help you turn that into a private note. Tell me when it started, how intense it feels, and whether anything makes it better or worse.",
  "I heard that. Before I save it, I want to check for urgent warning signs and then summarize the useful details.",
  "I can keep this as a local conversation and prepare a short version you can share with a clinician when you choose."
];

function currentTime() {
  return new Intl.DateTimeFormat([], {
    hour: "numeric",
    minute: "2-digit"
  }).format(new Date());
}

function appendMoment(kind, text) {
  const article = document.createElement("article");
  article.className = `moment ${kind}`;

  const time = document.createElement("time");
  time.textContent = `Today, ${currentTime()}`;

  const paragraph = document.createElement("p");
  paragraph.textContent = text;

  article.append(time, paragraph);
  timeline.append(article);
  timeline.scrollTop = timeline.scrollHeight;
}

function appendSummary(text) {
  const card = document.createElement("article");
  card.className = "listen-card";
  card.innerHTML = `
    <div class="listen-copy">
      <span class="mini-label">Local summary</span>
      <strong>${escapeHtml(text)}</strong>
      <span>Saved only on this device unless you export it.</span>
    </div>
    <button class="small-icon" type="button" aria-label="Edit summary">
      <span aria-hidden="true">Edit</span>
    </button>
  `;
  timeline.append(card);
  timeline.scrollTop = timeline.scrollHeight;
}

function appendMedicationDraft(fileName = "medication label photo") {
  const card = document.createElement("article");
  card.className = "med-draft";
  card.innerHTML = `
    <div class="draft-header">
      <span class="mini-label">Draft from photo</span>
      <strong>Metformin 500 mg</strong>
    </div>
    <dl class="draft-details">
      <div>
        <dt>Instruction found</dt>
        <dd>Take 1 tablet by mouth twice daily with meals.</dd>
      </div>
      <div>
        <dt>Source</dt>
        <dd>${escapeHtml(fileName)} &middot; processed on device</dd>
      </div>
    </dl>
    <div class="draft-actions">
      <button class="reply-chip" type="button">Approve reminder</button>
      <button class="reply-chip muted" type="button">Edit first</button>
    </div>
  `;
  timeline.append(card);
  timeline.scrollTop = timeline.scrollHeight;
}

function escapeHtml(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function sendMessage(text) {
  const cleanText = text.trim();
  if (!cleanText) return;

  appendMoment("user", cleanText);
  appendSummary(cleanText.length > 58 ? `${cleanText.slice(0, 58)}...` : cleanText);

  const reply = assistantReplies[Math.floor(Math.random() * assistantReplies.length)];
  window.setTimeout(() => appendMoment("assistant compact", reply), 280);
}

form.addEventListener("submit", (event) => {
  event.preventDefault();
  sendMessage(input.value);
  input.value = "";
});

quickActions.forEach((button) => {
  button.addEventListener("click", () => {
    if (!button.dataset.prompt) return;
    input.value = button.dataset.prompt;
    input.focus();
  });
});

photoMedButton.addEventListener("click", () => {
  medPhotoInput.click();
});

medPhotoInput.addEventListener("change", () => {
  const file = medPhotoInput.files[0];
  appendMoment("user", "I want to add a medication from a label photo.");
  window.setTimeout(() => {
    appendMedicationDraft(file ? file.name : undefined);
    appendMoment("assistant compact", "I drafted this from the label. Please check the medication name, dose, and timing before I create a local reminder.");
  }, 320);
  medPhotoInput.value = "";
});

micButton.addEventListener("click", () => {
  const isListening = micButton.classList.toggle("listening");
  micStatus.textContent = isListening ? "Listening" : "Off";
  micButton.setAttribute("aria-label", isListening ? "Stop listening" : "Hold to talk");

  if (isListening) {
    window.setTimeout(() => {
      if (!micButton.classList.contains("listening")) return;
      micButton.classList.remove("listening");
      micStatus.textContent = "Off";
      sendMessage("I have felt a little dizzy since breakfast, and I want to track it privately.");
    }, 1200);
  }
});
