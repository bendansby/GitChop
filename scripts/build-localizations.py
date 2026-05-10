#!/usr/bin/env python3
"""
Generate per-locale Localizable.strings files for GitChop.

The single source of truth lives in `TABLE` below: each English key
maps to a dict of locale → translation. Running this script writes
`localizations/<locale>.lproj/Localizable.strings` for every locale
listed in `LOCALES`. `scripts/build-app.sh` then copies those into
`GitChop.app/Contents/Resources/` at bundle time.

Verb names (pick / reword / edit / squash / fixup / drop) are
deliberately left in English across all locales — they're the literal
`git rebase -i` verbs and users would recognize them regardless of
locale. The verb *explanations* are translated.

Translations here are best-effort; native-speaker review is
recommended before a real release.

Usage:
    python3 scripts/build-localizations.py
"""
from pathlib import Path
import json

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "localizations"

LOCALES = ["en", "es", "fr", "de", "ja", "zh-Hans", "ko", "pt-BR"]

# ─────────────────────────────────────────────────────────────────────
# Translation table. Source key (English) → per-locale value.
# %@ = interpolated string, %lld = interpolated integer.
# ─────────────────────────────────────────────────────────────────────
TABLE = {
    # ── Buttons / common actions ────────────────────────────────────
    "Apply": {
        "es": "Aplicar", "fr": "Appliquer", "de": "Anwenden",
        "ja": "適用", "zh-Hans": "应用", "ko": "적용", "pt-BR": "Aplicar",
    },
    "Apply Rebase": {
        "es": "Aplicar rebase", "fr": "Appliquer le rebase", "de": "Rebase anwenden",
        "ja": "リベースを適用", "zh-Hans": "应用变基", "ko": "리베이스 적용", "pt-BR": "Aplicar rebase",
    },
    "Cancel": {
        "es": "Cancelar", "fr": "Annuler", "de": "Abbrechen",
        "ja": "キャンセル", "zh-Hans": "取消", "ko": "취소", "pt-BR": "Cancelar",
    },
    "Save": {
        "es": "Guardar", "fr": "Enregistrer", "de": "Sichern",
        "ja": "保存", "zh-Hans": "保存", "ko": "저장", "pt-BR": "Salvar",
    },
    "Done": {
        "es": "Listo", "fr": "Terminé", "de": "Fertig",
        "ja": "完了", "zh-Hans": "完成", "ko": "완료", "pt-BR": "Pronto",
    },
    "Reset": {
        "es": "Restablecer", "fr": "Réinitialiser", "de": "Zurücksetzen",
        "ja": "リセット", "zh-Hans": "重置", "ko": "재설정", "pt-BR": "Redefinir",
    },
    "Discard": {
        "es": "Descartar", "fr": "Ignorer", "de": "Verwerfen",
        "ja": "破棄", "zh-Hans": "放弃", "ko": "버리기", "pt-BR": "Descartar",
    },
    "Discard changes": {
        "es": "Descartar cambios", "fr": "Ignorer les modifications", "de": "Änderungen verwerfen",
        "ja": "変更を破棄", "zh-Hans": "放弃更改", "ko": "변경 사항 버리기", "pt-BR": "Descartar alterações",
    },
    "Continue": {
        "es": "Continuar", "fr": "Continuer", "de": "Fortfahren",
        "ja": "続行", "zh-Hans": "继续", "ko": "계속", "pt-BR": "Continuar",
    },
    "Skip commit": {
        "es": "Omitir commit", "fr": "Ignorer le commit", "de": "Commit überspringen",
        "ja": "コミットをスキップ", "zh-Hans": "跳过提交", "ko": "커밋 건너뛰기", "pt-BR": "Pular commit",
    },
    "Abort": {
        "es": "Abortar", "fr": "Abandonner", "de": "Abbrechen",
        "ja": "中止", "zh-Hans": "中止", "ko": "중단", "pt-BR": "Abortar",
    },
    "Refresh": {
        "es": "Actualizar", "fr": "Actualiser", "de": "Aktualisieren",
        "ja": "更新", "zh-Hans": "刷新", "ko": "새로 고침", "pt-BR": "Atualizar",
    },
    "Browse…": {
        "es": "Explorar…", "fr": "Parcourir…", "de": "Durchsuchen…",
        "ja": "選択…", "zh-Hans": "浏览…", "ko": "찾아보기…", "pt-BR": "Procurar…",
    },
    "Open": {
        "es": "Abrir", "fr": "Ouvrir", "de": "Öffnen",
        "ja": "開く", "zh-Hans": "打开", "ko": "열기", "pt-BR": "Abrir",
    },
    "Reveal": {
        "es": "Mostrar", "fr": "Afficher", "de": "Anzeigen",
        "ja": "表示", "zh-Hans": "显示", "ko": "표시", "pt-BR": "Mostrar",
    },
    "Add": {
        "es": "Añadir", "fr": "Ajouter", "de": "Hinzufügen",
        "ja": "追加", "zh-Hans": "添加", "ko": "추가", "pt-BR": "Adicionar",
    },
    "Copy": {
        "es": "Copiar", "fr": "Copier", "de": "Kopieren",
        "ja": "コピー", "zh-Hans": "拷贝", "ko": "복사", "pt-BR": "Copiar",
    },
    "Copy log": {
        "es": "Copiar registro", "fr": "Copier le journal", "de": "Protokoll kopieren",
        "ja": "ログをコピー", "zh-Hans": "拷贝日志", "ko": "로그 복사", "pt-BR": "Copiar log",
    },
    "Check for Updates…": {
        "es": "Buscar actualizaciones…", "fr": "Rechercher des mises à jour…", "de": "Nach Updates suchen…",
        "ja": "アップデートを確認…", "zh-Hans": "检查更新…", "ko": "업데이트 확인…", "pt-BR": "Procurar atualizações…",
    },
    "Close Repo": {
        "es": "Cerrar repositorio", "fr": "Fermer le dépôt", "de": "Repo schließen",
        "ja": "リポジトリを閉じる", "zh-Hans": "关闭仓库", "ko": "저장소 닫기", "pt-BR": "Fechar repositório",
    },
    "Open Repo…": {
        "es": "Abrir repositorio…", "fr": "Ouvrir le dépôt…", "de": "Repo öffnen…",
        "ja": "リポジトリを開く…", "zh-Hans": "打开仓库…", "ko": "저장소 열기…", "pt-BR": "Abrir repositório…",
    },

    # ── Sheet titles ────────────────────────────────────────────────
    "Split commit": {
        "es": "Dividir commit", "fr": "Diviser le commit", "de": "Commit aufteilen",
        "ja": "コミットを分割", "zh-Hans": "拆分提交", "ko": "커밋 분할", "pt-BR": "Dividir commit",
    },
    "Reword commit": {
        "es": "Reescribir mensaje", "fr": "Reformuler le commit", "de": "Commit-Nachricht neu schreiben",
        "ja": "コミットメッセージを編集", "zh-Hans": "修改提交信息", "ko": "커밋 메시지 수정", "pt-BR": "Reescrever commit",
    },
    "Resolve conflicts": {
        "es": "Resolver conflictos", "fr": "Résoudre les conflits", "de": "Konflikte lösen",
        "ja": "競合を解決", "zh-Hans": "解决冲突", "ko": "충돌 해결", "pt-BR": "Resolver conflitos",
    },
    "Couldn't load the diff": {
        "es": "No se pudo cargar el diff", "fr": "Impossible de charger le diff", "de": "Diff konnte nicht geladen werden",
        "ja": "差分を読み込めませんでした", "zh-Hans": "无法加载差异", "ko": "차이를 불러올 수 없습니다", "pt-BR": "Não foi possível carregar o diff",
    },
    "Nothing to split": {
        "es": "Nada que dividir", "fr": "Rien à diviser", "de": "Nichts aufzuteilen",
        "ja": "分割するものがありません", "zh-Hans": "无可拆分", "ko": "분할할 항목 없음", "pt-BR": "Nada para dividir",
    },
    "No repo loaded": {
        "es": "Sin repositorio cargado", "fr": "Aucun dépôt chargé", "de": "Kein Repo geladen",
        "ja": "リポジトリが読み込まれていません", "zh-Hans": "未加载仓库", "ko": "로드된 저장소 없음", "pt-BR": "Nenhum repositório carregado",
    },
    "No repos open": {
        "es": "No hay repositorios abiertos", "fr": "Aucun dépôt ouvert", "de": "Keine Repos geöffnet",
        "ja": "開いているリポジトリがありません", "zh-Hans": "无打开的仓库", "ko": "열린 저장소 없음", "pt-BR": "Nenhum repositório aberto",
    },
    "Backup ref": {
        "es": "Referencia de respaldo", "fr": "Référence de sauvegarde", "de": "Backup-Ref",
        "ja": "バックアップ ref", "zh-Hans": "备份 ref", "ko": "백업 ref", "pt-BR": "Ref de backup",
    },
    "Close this repo?": {
        "es": "¿Cerrar este repositorio?", "fr": "Fermer ce dépôt ?", "de": "Dieses Repo schließen?",
        "ja": "このリポジトリを閉じますか？", "zh-Hans": "关闭此仓库？", "ko": "이 저장소를 닫으시겠습니까?", "pt-BR": "Fechar este repositório?",
    },
    "Discard plan edits?": {
        "es": "¿Descartar cambios del plan?", "fr": "Ignorer les modifications du plan ?", "de": "Plan-Änderungen verwerfen?",
        "ja": "プランの変更を破棄しますか？", "zh-Hans": "放弃计划编辑？", "ko": "플랜 편집을 버리시겠습니까?", "pt-BR": "Descartar edições do plano?",
    },

    # ── Section labels ──────────────────────────────────────────────
    "HUNKS": {
        "es": "FRAGMENTOS", "fr": "BLOCS", "de": "HUNKS",
        "ja": "ハンク", "zh-Hans": "区块", "ko": "헝크", "pt-BR": "HUNKS",
    },
    "BUCKETS": {
        "es": "CESTAS", "fr": "GROUPES", "de": "GRUPPEN",
        "ja": "バケット", "zh-Hans": "分组", "ko": "버킷", "pt-BR": "GRUPOS",
    },
    "PLAN": {
        "es": "PLAN", "fr": "PLAN", "de": "PLAN",
        "ja": "プラン", "zh-Hans": "计划", "ko": "플랜", "pt-BR": "PLANO",
    },
    "BACKUP REF": {
        "es": "REF DE RESPALDO", "fr": "RÉF. DE SAUVEGARDE", "de": "BACKUP-REF",
        "ja": "バックアップ REF", "zh-Hans": "备份 REF", "ko": "백업 REF", "pt-BR": "REF DE BACKUP",
    },
    "DETAILS": {
        "es": "DETALLES", "fr": "DÉTAILS", "de": "DETAILS",
        "ja": "詳細", "zh-Hans": "详情", "ko": "상세 정보", "pt-BR": "DETALHES",
    },
    "What will change": {
        "es": "Qué cambiará", "fr": "Ce qui va changer", "de": "Was sich ändert",
        "ja": "変更内容", "zh-Hans": "将更改的内容", "ko": "변경될 내용", "pt-BR": "O que vai mudar",
    },
    "Original": {
        "es": "Original", "fr": "Original", "de": "Original",
        "ja": "元のメッセージ", "zh-Hans": "原文", "ko": "원본", "pt-BR": "Original",
    },
    "New subject": {
        "es": "Nuevo asunto", "fr": "Nouveau sujet", "de": "Neuer Betreff",
        "ja": "新しい件名", "zh-Hans": "新主题", "ko": "새 제목", "pt-BR": "Novo assunto",
    },
    "Conflicted files (%lld)": {
        "es": "Archivos en conflicto (%lld)", "fr": "Fichiers en conflit (%lld)", "de": "Konfliktdateien (%lld)",
        "ja": "競合ファイル (%lld)", "zh-Hans": "冲突文件 (%lld)", "ko": "충돌 파일 (%lld)", "pt-BR": "Arquivos em conflito (%lld)",
    },
    "Remaining commits (%lld)": {
        "es": "Commits restantes (%lld)", "fr": "Commits restants (%lld)", "de": "Verbleibende Commits (%lld)",
        "ja": "残りのコミット (%lld)", "zh-Hans": "剩余提交 (%lld)", "ko": "남은 커밋 (%lld)", "pt-BR": "Commits restantes (%lld)",
    },
    "Hunks (%lld)": {
        "es": "Fragmentos (%lld)", "fr": "Blocs (%lld)", "de": "Hunks (%lld)",
        "ja": "ハンク (%lld)", "zh-Hans": "区块 (%lld)", "ko": "헝크 (%lld)", "pt-BR": "Hunks (%lld)",
    },
    "Buckets (%lld)": {
        "es": "Cestas (%lld)", "fr": "Groupes (%lld)", "de": "Gruppen (%lld)",
        "ja": "バケット (%lld)", "zh-Hans": "分组 (%lld)", "ko": "버킷 (%lld)", "pt-BR": "Grupos (%lld)",
    },

    # ── Status messages ─────────────────────────────────────────────
    "Loading diff…": {
        "es": "Cargando diff…", "fr": "Chargement du diff…", "de": "Diff wird geladen…",
        "ja": "差分を読み込み中…", "zh-Hans": "正在加载差异…", "ko": "차이 불러오는 중…", "pt-BR": "Carregando diff…",
    },
    "Applying rebase…": {
        "es": "Aplicando rebase…", "fr": "Application du rebase…", "de": "Rebase wird angewendet…",
        "ja": "リベースを適用中…", "zh-Hans": "正在应用变基…", "ko": "리베이스 적용 중…", "pt-BR": "Aplicando rebase…",
    },
    "Applying…": {
        "es": "Aplicando…", "fr": "Application…", "de": "Wird angewendet…",
        "ja": "適用中…", "zh-Hans": "正在应用…", "ko": "적용 중…", "pt-BR": "Aplicando…",
    },
    "Working…": {
        "es": "Trabajando…", "fr": "En cours…", "de": "Wird ausgeführt…",
        "ja": "処理中…", "zh-Hans": "处理中…", "ko": "작업 중…", "pt-BR": "Processando…",
    },
    "All hunks assigned": {
        "es": "Todos los fragmentos asignados", "fr": "Tous les blocs assignés", "de": "Alle Hunks zugewiesen",
        "ja": "すべてのハンクが割り当てられました", "zh-Hans": "所有区块已分配", "ko": "모든 헝크 할당됨", "pt-BR": "Todos os hunks atribuídos",
    },
    "Ready to continue": {
        "es": "Listo para continuar", "fr": "Prêt à continuer", "de": "Bereit zum Fortfahren",
        "ja": "続行できます", "zh-Hans": "可以继续", "ko": "계속할 준비됨", "pt-BR": "Pronto para continuar",
    },
    "All conflicts resolved — ready to continue.": {
        "es": "Todos los conflictos resueltos — listo para continuar.",
        "fr": "Tous les conflits résolus — prêt à continuer.",
        "de": "Alle Konflikte gelöst — bereit zum Fortfahren.",
        "ja": "すべての競合が解決されました — 続行できます。",
        "zh-Hans": "所有冲突已解决 — 可以继续。",
        "ko": "모든 충돌 해결됨 — 계속할 준비됨.",
        "pt-BR": "Todos os conflitos resolvidos — pronto para continuar.",
    },
    "Open a git repo to start chopping commits.": {
        "es": "Abre un repositorio git para empezar a cortar commits.",
        "fr": "Ouvrez un dépôt git pour commencer à découper les commits.",
        "de": "Öffne ein Git-Repo, um Commits zu schneiden.",
        "ja": "git リポジトリを開いてコミットの編集を始めましょう。",
        "zh-Hans": "打开一个 git 仓库以开始处理提交。",
        "ko": "git 저장소를 열어 커밋 편집을 시작하세요.",
        "pt-BR": "Abra um repositório git para começar a cortar commits.",
    },
    "Open a git repo to begin.": {
        "es": "Abre un repositorio git para comenzar.",
        "fr": "Ouvrez un dépôt git pour commencer.",
        "de": "Öffne ein Git-Repo, um zu beginnen.",
        "ja": "git リポジトリを開いて始めましょう。",
        "zh-Hans": "打开一个 git 仓库开始。",
        "ko": "시작하려면 git 저장소를 여세요.",
        "pt-BR": "Abra um repositório git para começar.",
    },
    "Nothing left to apply": {
        "es": "Nada que aplicar", "fr": "Rien à appliquer", "de": "Nichts mehr anzuwenden",
        "ja": "適用するものはありません", "zh-Hans": "没有要应用的内容", "ko": "적용할 항목 없음", "pt-BR": "Nada para aplicar",
    },
    "Resolving this commit will finish the rebase.": {
        "es": "Resolver este commit terminará el rebase.",
        "fr": "Résoudre ce commit terminera le rebase.",
        "de": "Mit der Lösung dieses Commits ist der Rebase abgeschlossen.",
        "ja": "このコミットを解決するとリベースが完了します。",
        "zh-Hans": "解决此提交将完成变基。",
        "ko": "이 커밋을 해결하면 리베이스가 완료됩니다.",
        "pt-BR": "Resolver este commit finalizará o rebase.",
    },
    "Will rewrite this commit's message": {
        "es": "Reescribirá el mensaje de este commit",
        "fr": "Le message de ce commit sera réécrit",
        "de": "Die Commit-Nachricht wird neu geschrieben",
        "ja": "このコミットのメッセージを書き換えます",
        "zh-Hans": "将重写此提交的消息",
        "ko": "이 커밋의 메시지가 다시 작성됩니다",
        "pt-BR": "A mensagem deste commit será reescrita",
    },
    "Empty — saving will leave the original intact": {
        "es": "Vacío — al guardar se mantendrá el original",
        "fr": "Vide — l'enregistrement laissera l'original intact",
        "de": "Leer — beim Sichern bleibt das Original erhalten",
        "ja": "空 — 保存しても元の内容は変更されません",
        "zh-Hans": "为空 — 保存后将保留原文",
        "ko": "비어 있음 — 저장해도 원본이 그대로 유지됩니다",
        "pt-BR": "Vazio — salvar manterá o original",
    },
    "Unchanged — saving will leave it as-is": {
        "es": "Sin cambios — al guardar quedará igual",
        "fr": "Inchangé — l'enregistrement le laissera tel quel",
        "de": "Unverändert — beim Sichern bleibt es so wie es ist",
        "ja": "変更なし — 保存してもそのままです",
        "zh-Hans": "未更改 — 保存后将保持原样",
        "ko": "변경 없음 — 저장해도 그대로입니다",
        "pt-BR": "Sem alterações — salvar manterá como está",
    },

    # ── Verb explanations ───────────────────────────────────────────
    "Keep this commit as-is": {
        "es": "Mantener este commit tal cual", "fr": "Conserver ce commit tel quel", "de": "Diesen Commit unverändert lassen",
        "ja": "このコミットをそのまま保持", "zh-Hans": "保留此提交不变", "ko": "이 커밋을 그대로 유지", "pt-BR": "Manter este commit como está",
    },
    "Edit this commit's message": {
        "es": "Editar el mensaje de este commit", "fr": "Modifier le message de ce commit", "de": "Commit-Nachricht bearbeiten",
        "ja": "このコミットのメッセージを編集", "zh-Hans": "编辑此提交的信息", "ko": "이 커밋의 메시지 편집", "pt-BR": "Editar a mensagem deste commit",
    },
    "Split this commit into multiple smaller commits": {
        "es": "Dividir este commit en varios más pequeños",
        "fr": "Diviser ce commit en plusieurs plus petits",
        "de": "Diesen Commit in mehrere kleinere aufteilen",
        "ja": "このコミットを複数の小さなコミットに分割",
        "zh-Hans": "将此提交拆分成多个较小的提交",
        "ko": "이 커밋을 여러 작은 커밋으로 분할",
        "pt-BR": "Dividir este commit em vários menores",
    },
    "Combine into the previous commit, keeping both messages": {
        "es": "Combinar con el commit anterior, conservando ambos mensajes",
        "fr": "Fusionner avec le commit précédent en gardant les deux messages",
        "de": "Mit dem vorherigen Commit zusammenführen, beide Nachrichten behalten",
        "ja": "前のコミットと結合し、両方のメッセージを保持",
        "zh-Hans": "合并到上一个提交,保留两条信息",
        "ko": "이전 커밋과 결합, 두 메시지 모두 유지",
        "pt-BR": "Combinar com o commit anterior, mantendo ambas as mensagens",
    },
    "Combine into the previous commit, dropping this message": {
        "es": "Combinar con el commit anterior, descartando este mensaje",
        "fr": "Fusionner avec le commit précédent en supprimant ce message",
        "de": "Mit dem vorherigen Commit zusammenführen, diese Nachricht verwerfen",
        "ja": "前のコミットと結合し、このメッセージは破棄",
        "zh-Hans": "合并到上一个提交,丢弃此信息",
        "ko": "이전 커밋과 결합, 이 메시지는 버림",
        "pt-BR": "Combinar com o commit anterior, descartando esta mensagem",
    },
    "Remove this commit entirely": {
        "es": "Eliminar este commit por completo",
        "fr": "Supprimer entièrement ce commit",
        "de": "Diesen Commit vollständig entfernen",
        "ja": "このコミットを完全に削除",
        "zh-Hans": "完全删除此提交",
        "ko": "이 커밋을 완전히 제거",
        "pt-BR": "Remover este commit completamente",
    },

    # ── Preferences ─────────────────────────────────────────────────
    "General": {
        "es": "General", "fr": "Général", "de": "Allgemein",
        "ja": "一般", "zh-Hans": "通用", "ko": "일반", "pt-BR": "Geral",
    },
    "Git": {
        "es": "Git", "fr": "Git", "de": "Git",
        "ja": "Git", "zh-Hans": "Git", "ko": "Git", "pt-BR": "Git",
    },
    "Editor": {
        "es": "Editor", "fr": "Éditeur", "de": "Editor",
        "ja": "エディタ", "zh-Hans": "编辑器", "ko": "에디터", "pt-BR": "Editor",
    },
    "Default depth": {
        "es": "Profundidad por defecto", "fr": "Profondeur par défaut", "de": "Standardtiefe",
        "ja": "デフォルトの深さ", "zh-Hans": "默认深度", "ko": "기본 깊이", "pt-BR": "Profundidade padrão",
    },
    "Path to git": {
        "es": "Ruta a git", "fr": "Chemin vers git", "de": "Pfad zu git",
        "ja": "git のパス", "zh-Hans": "git 路径", "ko": "git 경로", "pt-BR": "Caminho do git",
    },
    "Use $PATH (default)": {
        "es": "Usar $PATH (predeterminado)", "fr": "Utiliser $PATH (par défaut)", "de": "$PATH verwenden (Standard)",
        "ja": "$PATH を使用 (既定)", "zh-Hans": "使用 $PATH(默认)", "ko": "$PATH 사용 (기본값)", "pt-BR": "Usar $PATH (padrão)",
    },
    "Open conflicted files in": {
        "es": "Abrir archivos en conflicto en", "fr": "Ouvrir les fichiers en conflit dans", "de": "Konfliktdateien öffnen in",
        "ja": "競合ファイルの起動先", "zh-Hans": "在以下应用中打开冲突文件", "ko": "충돌 파일을 다음에서 열기", "pt-BR": "Abrir arquivos em conflito em",
    },
    "macOS default": {
        "es": "Predeterminado de macOS", "fr": "Par défaut de macOS", "de": "macOS-Standard",
        "ja": "macOS の既定", "zh-Hans": "macOS 默认", "ko": "macOS 기본값", "pt-BR": "Padrão do macOS",
    },
    "Specific app…": {
        "es": "App específica…", "fr": "App spécifique…", "de": "Bestimmte App…",
        "ja": "特定の App…", "zh-Hans": "指定 App…", "ko": "특정 App…", "pt-BR": "App específico…",
    },
    "Shell command": {
        "es": "Comando de shell", "fr": "Commande shell", "de": "Shell-Befehl",
        "ja": "シェルコマンド", "zh-Hans": "Shell 命令", "ko": "셸 명령", "pt-BR": "Comando shell",
    },

    # ── Empty / placeholder ─────────────────────────────────────────
    "Commit message": {
        "es": "Mensaje del commit", "fr": "Message du commit", "de": "Commit-Nachricht",
        "ja": "コミットメッセージ", "zh-Hans": "提交信息", "ko": "커밋 메시지", "pt-BR": "Mensagem do commit",
    },
    "Subject": {
        "es": "Asunto", "fr": "Sujet", "de": "Betreff",
        "ja": "件名", "zh-Hans": "主题", "ko": "제목", "pt-BR": "Assunto",
    },
    "Assign hunks to this commit": {
        "es": "Asignar fragmentos a este commit", "fr": "Assigner des blocs à ce commit", "de": "Hunks diesem Commit zuweisen",
        "ja": "ハンクをこのコミットに割り当てる", "zh-Hans": "将区块分配给此提交", "ko": "이 커밋에 헝크 할당", "pt-BR": "Atribuir hunks a este commit",
    },
    "Unassigned": {
        "es": "Sin asignar", "fr": "Non assigné", "de": "Nicht zugewiesen",
        "ja": "未割り当て", "zh-Hans": "未分配", "ko": "할당되지 않음", "pt-BR": "Não atribuído",
    },
    "Bucket %lld": {
        "es": "Cesta %lld", "fr": "Groupe %lld", "de": "Gruppe %lld",
        "ja": "バケット %lld", "zh-Hans": "分组 %lld", "ko": "버킷 %lld", "pt-BR": "Grupo %lld",
    },
    "Commit %lld": {
        "es": "Commit %lld", "fr": "Commit %lld", "de": "Commit %lld",
        "ja": "コミット %lld", "zh-Hans": "提交 %lld", "ko": "커밋 %lld", "pt-BR": "Commit %lld",
    },

    # ── Conflict copy ───────────────────────────────────────────────
    "Git stopped on a commit that doesn't apply cleanly. Resolve the listed files in your editor, then click Continue.": {
        "es": "Git se detuvo en un commit que no se aplica limpiamente. Resuelve los archivos listados en tu editor y luego pulsa Continuar.",
        "fr": "Git s'est arrêté sur un commit qui ne s'applique pas proprement. Résolvez les fichiers listés dans votre éditeur, puis cliquez sur Continuer.",
        "de": "Git ist bei einem Commit angehalten, der nicht sauber angewendet werden kann. Löse die aufgeführten Dateien in deinem Editor und klicke auf Fortfahren.",
        "ja": "クリーンに適用できないコミットで Git が停止しました。エディタでリストのファイルを解決し、続行をクリックしてください。",
        "zh-Hans": "Git 在无法干净应用的提交处停止。请在编辑器中解决列出的文件,然后点击「继续」。",
        "ko": "깔끔하게 적용되지 않는 커밋에서 Git이 멈췄습니다. 나열된 파일을 에디터에서 해결한 후 계속을 누르세요.",
        "pt-BR": "O Git parou em um commit que não aplica de forma limpa. Resolva os arquivos listados no seu editor e clique em Continuar.",
    },
    "Binary — can't split. Goes to bucket 1.": {
        "es": "Binario — no se puede dividir. Va a la cesta 1.",
        "fr": "Binaire — ne peut être divisé. Va dans le groupe 1.",
        "de": "Binär — kann nicht aufgeteilt werden. Geht in Gruppe 1.",
        "ja": "バイナリ — 分割できません。バケット 1 に入ります。",
        "zh-Hans": "二进制 — 无法拆分。归入分组 1。",
        "ko": "이진 — 분할할 수 없음. 버킷 1로 이동.",
        "pt-BR": "Binário — não pode ser dividido. Vai para o grupo 1.",
    },
    "This commit has no hunks GitChop can split — likely a merge commit, a binary-only delta, or an empty commit.": {
        "es": "Este commit no tiene fragmentos que GitChop pueda dividir — probablemente un commit de fusión, un delta solo binario o un commit vacío.",
        "fr": "Ce commit n'a aucun bloc que GitChop puisse diviser — probablement un commit de fusion, un delta binaire uniquement, ou un commit vide.",
        "de": "Dieser Commit hat keine Hunks, die GitChop aufteilen kann — wahrscheinlich ein Merge-Commit, ein reiner Binär-Delta oder ein leerer Commit.",
        "ja": "GitChop が分割できるハンクがありません — マージコミット、バイナリのみの差分、または空のコミットの可能性があります。",
        "zh-Hans": "此提交没有 GitChop 可拆分的区块 — 可能是合并提交、纯二进制差异或空提交。",
        "ko": "GitChop이 분할할 수 있는 헝크가 없습니다 — 병합 커밋, 이진 전용 델타 또는 빈 커밋일 가능성이 있습니다.",
        "pt-BR": "Este commit não tem hunks que o GitChop possa dividir — provavelmente um commit de merge, um delta apenas binário ou um commit vazio.",
    },
}


def write_strings_file(locale: str, table: dict) -> Path:
    """
    Write `<locale>.lproj/Localizable.strings` (.strings format,
    UTF-16 LE BOM + utf-8 escapes — actually plain UTF-8 with quotes
    is fine for modern macOS, which is what we use here).
    """
    out = OUT_DIR / f"{locale}.lproj" / "Localizable.strings"
    out.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        "/*",
        f" * GitChop — Localizable.strings (locale: {locale})",
        " * Generated by scripts/build-localizations.py — do not edit by hand.",
        " * Verb names (pick/reword/edit/squash/fixup/drop) intentionally",
        " * stay in English across all locales.",
        " */",
        "",
    ]
    for src in sorted(table.keys()):
        if locale == "en":
            value = src
        else:
            value = table[src].get(locale, src)
        # Escape backslashes and quotes for .strings format.
        esc_src = src.replace("\\", "\\\\").replace('"', '\\"')
        esc_val = value.replace("\\", "\\\\").replace('"', '\\"')
        lines.append(f'"{esc_src}" = "{esc_val}";')
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return out


def main():
    OUT_DIR.mkdir(exist_ok=True)
    written = []
    for locale in LOCALES:
        path = write_strings_file(locale, TABLE)
        written.append(path)
    print(f"Wrote {len(written)} files under {OUT_DIR}:")
    for p in written:
        print(f"  • {p.relative_to(ROOT)}  ({len(TABLE)} keys)")


if __name__ == "__main__":
    main()
