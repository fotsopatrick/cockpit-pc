// Cockpit PC — interface du serveur local
(() => {
  "use strict";

  let dernieres = null;
  let filtres = { conn: "", entrantes: "", svc: "", taches: "", logs: "" };

  const $ = (id) => document.getElementById(id);

  // --- horloge + onglets ---
  setInterval(() => {
    $("horloge").textContent = new Date().toLocaleTimeString("fr-FR");
  }, 1000);

  document.querySelectorAll(".onglet").forEach((b) => {
    b.addEventListener("click", () => {
      document.querySelectorAll(".onglet").forEach((x) => x.classList.remove("actif"));
      document.querySelectorAll(".panneau").forEach((x) => x.classList.remove("actif"));
      b.classList.add("actif");
      $(b.dataset.panel).classList.add("actif");
    });
  });

  ["chConn", "chEntrantes", "chSvc", "chTaches", "chLogs"].forEach((id) => {
    $(id).addEventListener("input", (e) => {
      const m = id.slice(2).toLowerCase();
      filtres[m] = e.target.value.toLowerCase();
      rendre();
    });
  });

  $("btnArret").addEventListener("click", async () => {
    if (!confirm("Arrêter le serveur Cockpit PC ?")) return;
    try { await fetch("/api/arret"); } catch (e) {}
    $("etatServeur").textContent = "serveur : arrêté";
  });

  // --- echappement ---
  const esc = (s) => {
    if (s === null || s === undefined) return "";
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  };

  const etiquettes = {
    Running: 'vert', Running: 'vert', Stopped: 'rouge',
    Ready: 'vert', Disabled: 'gris', Running: 'vert',
    Auto: 'cyan', Manual: 'gris', Unknown: 'jaune'
  };

  // --- bandeaux ---
  function bandeaux(d) {
    const cr = d.cpuRam;
    setStat($("stCpu"), cr.cpu + " %", cr.cpu);
    setStat($("stRam"), cr.ramUse + " / " + cr.ramTotal + " Go", cr.ramPct);
    const disq = d.disques.length ? d.disques[0] : null;
    setStat($("stDisq"), disq ? disq.libre + " / " + disq.total + " Go" : "–", disq ? disq.pct : 0);
    $("stSvc").querySelector(".valeur").textContent = d.services.countActifs ?? "–";
    $("stConx").querySelector(".valeur").textContent = d.connexions.length;
    $("stPorts").querySelector(".valeur").textContent = d.ports.length;

    $("sousTitre").textContent = d.machine.nom + " · " + d.machine.ip + " · " + d.machine.version;
    $("etatServeur").textContent = "serveur : actif depuis " + d.machine.serveurDepuis;
    $("derniereMaj").textContent = "mis à jour " + d.horodatage;

    const voyants = [];
    const nvSvc = d.installations.length;
    const erreurs = d.erreurs.length;
    const connEtrangeres = d.connexions.length;
    voyants.push({ titre: "nouveaux services depuis le 01/08", n: nvSvc, seuil: 5, c: "jaune" });
    voyants.push({ titre: "erreurs 24h", n: erreurs, seuil: 3, c: "rouge" });
    voyants.push({ titre: "connexions sortantes", n: connEtrangeres, seuil: 12, c: "cyan" });
    $("voyants").innerHTML = voyants.map((v) =>
      `<span title="${v.titre} : ${v.n}" class="voyant ${v.n >= v.seuil ? v.c : "vert"}"></span>`
    ).join("");
  }

  function setStat(boite, txt, pct) {
    boite.querySelector(".valeur").textContent = txt;
    const bar = boite.querySelector(".remplissage");
    bar.style.width = Math.min(100, pct) + "%";
    bar.className = "remplissage " + (pct > 85 ? "rouge" : pct > 65 ? "jaune" : "");
  }

  // --- vue d'ensemble ---
  function resume(d) {
    // nouveaux services (uniques par nom, tries par date)
    const svc = d.installations.slice().sort((a, b) => b.date.localeCompare(a.date));
    $("resNouveauxServices").innerHTML =
      (svc.length ? svc.map((s) =>
        `<div class="ligne"><span class="quand">${esc(s.date)}</span><span class="quoi">${esc(s.nom)}</span><span class="tag ${s.demarrage && s.demarrage.includes('automatique') ? 'cyan' : 'gris'}">${esc(s.demarrage || '')}</span></div>`
      ) : `<div class="vide">Aucun service installé depuis le 01/08.</div>`).join("");

    $("resLogiciels").innerHTML =
      (d.logiciels.length ? d.logiciels.slice(0, 15).map((l) =>
        `<div class="ligne"><span class="quand">${esc(l.date)}</span><span class="quoi">${esc(l.nom)} ${esc(l.version || '')}</span></div>`
      ) : `<div class="vide">Rien d'installé depuis le 01/08.</div>`).join("");

    $("resErreurs").innerHTML =
      (d.erreurs.length ? d.erreurs.slice(0, 10).map((e) =>
        `<div class="ligne"><span class="quand">${esc(e.date)}</span><span class="quoi">[${esc(e.log)}] ${esc(e.source)} : ${esc(e.msg)}</span></div>`
      ) : `<div class="vide">Aucune erreur système sur 24 h.</div>`).join("");

    $("resProcessus").innerHTML =
      d.processus.slice(0, 10).map((p) =>
        `<div class="ligne"><span class="quoi">${esc(p.nom)} <span class="tag gris">pid ${p.pid}</span></span><span class="quand">${p.mem} Mo</span></div>`
      ).join("");

    $("resFrequences").innerHTML =
      (d.frequences.length ? d.frequences.slice(0, 20).map((f) =>
        `<div class="ligne"><span class="quoi">${esc(f.proc)} → ${esc(f.ip)}:${esc(f.port)}</span><span class="quand">${f.n} fois · ${esc(f.dernier)}</span></div>`
      ) : `<div class="vide">Aucune connexion enregistrée pour l'instant.</div>`).join("");

    $("resFrequencesEntrantes").innerHTML =
      (d.frequencesEntrantes.length ? d.frequencesEntrantes.slice(0, 20).map((f) =>
        `<div class="ligne"><span class="quoi">${esc(f.proc)} ← ${esc(f.ip)}:${esc(f.port)}</span><span class="quand">${f.n} fois · ${esc(f.dernier)}</span></div>`
      ) : `<div class="vide">Aucune connexion entrante enregistrée pour l'instant.</div>`).join("");
  }

  // --- reseau ---
  function reseau(d) {
    const f = filtres.conn;
    const liste = d.connexions
      .filter((c) => {
        const ch = (c.proc + " " + c.ip + " " + c.port + " " + (c.hote || "")).toLowerCase();
        return !f || ch.includes(f);
      })
      .sort((a, b) => (a.proc < b.proc ? -1 : 1));
    $("resConnexions").innerHTML = `<table><thead><tr><th>Processus</th><th>Pid</th><th>État</th><th>IP distante</th><th>Port</th><th>Hôte</th></tr></thead><tbody>` +
      (liste.length ? liste.map((c) =>
        `<tr><td>${esc(c.proc)}</td><td>${c.pid}</td><td>${esc(c.etat)}</td><td>${esc(c.ip)}</td><td>${c.port}</td><td>${esc(c.hote || '')}</td></tr>`
      ).join("") : `<tr><td colspan="6" class="vide">Aucune connexion.</td></tr>`) +
      `</tbody></table>`;

    const fEnt = filtres.entrantes;
    const entrees = (d.connexionsEntrantes || [])
      .filter((c) => {
        const ch = (c.proc + " " + c.ip + " " + c.port + " " + (c.hote || "")).toLowerCase();
        return !fEnt || ch.includes(fEnt);
      })
      .sort((a, b) => (a.proc < b.proc ? -1 : 1));
    $("resConnexionsEntrantes").innerHTML = `<table><thead><tr><th>Processus</th><th>Pid</th><th>IP distante</th><th>Port local</th><th>Adresse locale</th><th>Hôte</th></tr></thead><tbody>` +
      (entrees.length ? entrees.map((c) =>
        `<tr><td>${esc(c.proc)}</td><td>${c.pid}</td><td>${esc(c.ip)}</td><td>${c.port}</td><td>${esc(c.local || '')}</td><td>${esc(c.hote || '')}</td></tr>`
      ).join("") : `<tr><td colspan="6" class="vide">Aucune connexion entrante.</td></tr>`) +
      `</tbody></table>`;

    const ports = d.ports.slice().sort((a, b) => a.port - b.port);
    $("resPorts").innerHTML = `<table><thead><tr><th>Port</th><th>Processus</th><th>Pid</th><th>Adresse</th></tr></thead><tbody>` +
      ports.map((p) =>
        `<tr><td>${p.port}</td><td>${esc(p.proc || '')}</td><td>${p.pid}</td><td>${esc(p.addr)}</td></tr>`
      ).join("") + `</tbody></table>`;
  }

  // --- services & taches ---
  function services(d) {
    const f = filtres.svc;
    const svc = d.services.services
      .filter((s) => {
        const ch = (s.nom + " " + s.affiche + " " + (s.chemin || "")).toLowerCase();
        return !f || ch.includes(f);
      })
      .sort((a, b) => a.nom.localeCompare(b.nom));
    $("resServices").innerHTML = `<table><thead><tr><th>Service</th><th>État</th><th>Démarrage</th><th>Installé le</th><th>Chemin</th></tr></thead><tbody>` +
      (svc.length ? svc.map((s) =>
        `<tr><td>${esc(s.nom)}</td><td><span class="tag ${s.etat === 'Running' ? 'vert' : 'rouge'}">${esc(s.etat)}</span></td><td>${esc(s.demarrage)}</td><td>${esc(s.installeLe || '')}</td><td>${esc(s.chemin || '')}</td></tr>`
      ).join("") : `<tr><td colspan="5" class="vide">Aucun service.</td></tr>`) + `</tbody></table>`;

    const f2 = filtres.taches;
    const nonMs = d.taches.filter((t) => !t.ms).sort((a, b) => (b.dernier || "").localeCompare(a.dernier || ""));
    const ms = d.taches.filter((t) => t.ms);
    $("resTaches").innerHTML = `<div class="note">${nonMs.length} tâches personnelles · ${ms.length} tâches système</div>` +
      `<table><thead><tr><th>Tâche</th><th>État</th><th>Dernière exécution</th><th>Commande</th></tr></thead><tbody>` +
      nonMs.filter((t) => {
        const ch = (t.nom + " " + t.chemin + " " + t.cmd).toLowerCase();
        return !f2 || ch.includes(f2);
      }).map((t) =>
        `<tr><td>${esc(t.nom)}</td><td><span class="tag ${t.etat === 'Ready' ? 'vert' : 'gris'}">${esc(t.etat)}</span></td><td>${esc(t.dernier || '—')}</td><td>${esc(t.cmd || '')}</td></tr>`
      ).join("") + `</tbody></table>`;
  }

  // --- systeme ---
  function systeme(d) {
    $("resAutostart").innerHTML =
      (d.autostart.length ? d.autostart.map((a) =>
        `<div class="ligne"><span class="quand">${esc(a.cle)}</span><span class="quoi">${esc(a.nom)} → ${esc(a.cmd)}</span></div>`
      ) : `<div class="vide">Rien au démarrage.</div>`).join("");

    const m = d.machine;
    const cr = d.cpuRam;
    $("resMachine").innerHTML = [
      `<div class="ligne"><span class="quand">Nom</span><span class="quoi">${esc(m.nom)}</span></div>`,
      `<div class="ligne"><span class="quand">Utilisateur</span><span class="quoi">${esc(m.user)}</span></div>`,
      `<div class="ligne"><span class="quand">IP locale</span><span class="quoi">${esc(m.ip || '—')}</span></div>`,
      `<div class="ligne"><span class="quand">Système</span><span class="quoi">${esc(m.version)}</span></div>`,
      `<div class="ligne"><span class="quand">RAM</span><span class="quoi">${cr.ramUse} / ${cr.ramTotal} Go utilisés</span></div>`,
      `<div class="ligne"><span class="quand">Système allumé depuis</span><span class="quoi">${cr.systemeUp.toFixed(1)} jours</span></div>`
    ].join("");

    $("resDisques").innerHTML =
      (d.disques.length ? d.disques.map((x) =>
        `<div class="ligne"><span class="quand">${esc(x.lettre)}</span><span class="quoi">${x.libre} Go libres sur ${x.total} Go</span><span class="tag ${x.pct < 15 ? 'rouge' : x.pct < 30 ? 'jaune' : 'vert'}">${x.pct}% libres</span></div>`
      ) : `<div class="vide">Aucun disque.</div>`).join("");
  }

  // --- journal ---
  function journal(d) {
    const f = filtres.logs;
    const logs = d.logs.filter((l) => {
      const ch = JSON.stringify(l).toLowerCase();
      return !f || ch.includes(f);
    });
    $("resLogs").innerHTML = `<table><thead><tr><th>Heure</th><th>Type</th><th>Détail</th></tr></thead><tbody>` +
      (logs.length ? logs.map((l) => {
        let detail = "";
        let tag = "gris";
        if (l.type === "connexion") {
          detail = `${esc(l.proc)} → ${esc(l.ip)}:${esc(l.port)}${l.hote ? " (" + esc(l.hote) + ")" : ""}`;
          tag = "cyan";
        } else if (l.type === "entree") {
          detail = `Connexion ENTRANTE : ${esc(l.ip)}:${esc(l.port)} → ${esc(l.proc)}${l.hote ? " (" + esc(l.hote) + ")" : ""}`;
          tag = "rouge";
        } else if (l.type === "terminal") {
          detail = `Nouvelle fenêtre ${esc(l.nom)} (pid ${l.pid}, parent ${l.parent}) : ${esc(l.cmd || "")}`;
          tag = "violet";
        } else if (l.type === "service-nouveau" || l.type === "service-disparu") {
          detail = `${l.type === "service-nouveau" ? "Service apparu" : "Service disparu"} : ${esc(l.nom)}`;
          tag = "jaune";
        } else if (l.type === "service-etat") {
          detail = `Service ${esc(l.nom)} : ${esc(l.avant)} → ${esc(l.apres)}`;
          tag = "jaune";
        }
        return `<tr><td>${esc(l.date)}</td><td><span class="tag ${tag}">${esc(l.type)}</span></td><td>${detail}</td></tr>`;
      }).join("") : `<tr><td colspan="3" class="vide">Rien dans le journal.</td></tr>`) + `</tbody></table>`;
  }

  // --- rendu global ---
  function rendre() {
    if (!dernieres) return;
    const d = dernieres;
    bandeaux(d);
    resume(d);
    reseau(d);
    services(d);
    systeme(d);
    journal(d);
  }

  async function maj() {
    try {
      const r = await fetch("/api/vue", { cache: "no-store" });
      if (!r.ok) throw new Error("http " + r.status);
      dernieres = await r.json();
      rendre();
    } catch (e) {
      $("sousTitre").textContent = "serveur injoignable — relancez depuis le Bureau";
      $("etatServeur").textContent = "serveur : hors ligne";
    }
  }

  maj();
  setInterval(maj, 6000);
})();
