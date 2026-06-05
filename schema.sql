-- =====================================================================
-- 半导体运营管理系统 · MySQL DDL
-- 与 原型.html 数据模型 1:1 对齐；ENUM 字面量与 JS 端 RULES / 状态枚举一致
--
-- 命名约定：
--   * 实体表：单数（alarm / issue / meeting / topic / report_doc / event / notification）
--   * 引用数据：ref_* 前缀（管理员可编辑、不进业务状态机）
--   * 子表 / 快照：<父>_<内容> 前缀（issue_approval_chain 等）
--
-- ID 策略：业务实体保留字符串 ID（ISS-/AL-/TPC-/RPT-/M-…），与原型深链/事件 body 引用语义一致；
--          仅 event / notification / 纯子表行用自增 BIGINT。
--
-- 字符集：utf8mb4 / utf8mb4_0900_ai_ci（含表情符号兼容；列存中文标签）
-- 引擎：InnoDB（外键 + 行级锁）
-- =====================================================================

SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;

-- =====================================================================
-- 1. 引用数据（Tier-1 reference · 管理员可编辑 · 不进业务状态机）
--    对应 RULES.siteOwners / engineerTeams / piRegistry / approvalLadder
-- =====================================================================

-- 站点 → 站点负责人（site→owner 注册表 · 决策 #5）
-- Issue 创建时按 site 解析 owner，并 snapshot 进 issue.owner
CREATE TABLE ref_site_owner (
  site         VARCHAR(64)  NOT NULL,
  owner_name   VARCHAR(64)  NOT NULL,
  updated_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (site)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 工程师 → team（engineer→team 注册表 · 决策 #5 所有权共享）
-- Issue 创建时按 owner 解析 team，并 snapshot 进 issue.team；
-- alarm 分诊层无 snapshot → 走动态 lookup
CREATE TABLE ref_engineer_team (
  engineer_name VARCHAR(64) NOT NULL,
  team_name     VARCHAR(64) NOT NULL,
  updated_at    DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (engineer_name),
  KEY idx_team (team_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- site/工序 → PI 列表（决策 #12 · 一个 site 可对应多 PI）
-- Issue 创建时按 site snapshot 一组 PI 进 issue_pi_reviewer
CREATE TABLE ref_site_pi (
  site       VARCHAR(64) NOT NULL,
  pi_name    VARCHAR(64) NOT NULL,
  updated_at DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (site, pi_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 审批阶梯（决策 #5 · 单调上行，level 1 = 直接主管）
-- Issue 创建时按 level 顺序快照进 issue_approval_chain，default_name 仅作 snapshot 时回填用
CREATE TABLE ref_approval_ladder (
  level         INT         NOT NULL,
  role          VARCHAR(64) NOT NULL,    -- 三级经理 / 四级经理 / 五级经理
  default_name  VARCHAR(64),             -- 演示用：刘经理/周经理/吴总
  PRIMARY KEY (level)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- =====================================================================
-- 2. Alarm（事实告警 · 只读证据 + 薄运营覆盖 · 决策 #1/#2）
-- =====================================================================
CREATE TABLE alarm (
  id                  VARCHAR(32)  NOT NULL,                -- AL-XXXX
  site                VARCHAR(64)  NOT NULL,
  type                VARCHAR(128) NOT NULL,
  severity            ENUM('high','mid','low') NOT NULL,
  occurred_at         DATETIME     NOT NULL,                -- 上游事实（原型 hAgo 折算）
  -- 薄运营覆盖：分诊状态机
  status              ENUM('未分诊','已ack','已忽略','已升级')
                      NOT NULL DEFAULT '未分诊',
  escalated_issue_id  VARCHAR(32),                          -- 升级后绑定的 Issue
  acked_by            VARCHAR(64),
  acked_at            DATETIME,
  -- 同步元数据
  synced_at           DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_status      (status),
  KEY idx_site_type   (site, type),                         -- 分诊收件箱"可聚合"判定
  KEY idx_occurred    (occurred_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- =====================================================================
-- 3. Issue（核心实体 · "重心" · 决策 #1）
-- =====================================================================
CREATE TABLE issue (
  id                       VARCHAR(32)  NOT NULL,           -- ISS-XXXX
  title                    VARCHAR(255) NOT NULL,
  site                     VARCHAR(64)  NOT NULL,
  owner                    VARCHAR(64),                     -- snapshot at creation (site→owner)
  team                     VARCHAR(64),                     -- snapshot at creation (engineer→team)

  -- 状态机：决策 #4 · 四态 + current_level 游标实现多级审批
  status                   ENUM('处理中','审批中','已解决','已关闭') NOT NULL,
  current_level            INT          NOT NULL DEFAULT 0, -- 0=未在审批；>=1=审批游标
  pinned                   BOOLEAN      NOT NULL DEFAULT FALSE,

  -- 来源（决策 #2 补 · 事实字段）
  source                   ENUM('triage','external-MES','external-SPC') NOT NULL,
  source_alarm_id          VARCHAR(32),                     -- 仅 source=triage 时可能有值

  -- 描述
  description              TEXT,
  root_cause               TEXT,

  -- 上游事实（只读）
  chart_level              ENUM('KIP','ACP'),               -- 主控图等级

  -- 诊断（决策 #10 · 工程师对 Issue 的诊断 · 提交审批前必填）
  diagnosis_subtype        ENUM('工艺漂移','设备异常','物料批次','量测误差','软件配置','其他'),
  diagnosis_detection      VARCHAR(200),                    -- ≤200 字

  -- 因子层：Kanban（决策 #9 · 自动判定 + 人工可覆盖留痕）
  kanban                   BOOLEAN      NOT NULL DEFAULT FALSE,
  kanban_auto              BOOLEAN      NOT NULL DEFAULT FALSE,  -- 规则自动判定结果
  kanban_override_value    BOOLEAN,                         -- 人工覆盖值（null = 未覆盖）
  kanban_override_reason   TEXT,
  kanban_override_by       VARCHAR(64),
  kanban_override_at       DATETIME,

  -- 因子层：Risk（决策 #9 · 同上）
  risk                     ENUM('低','中','高') NOT NULL DEFAULT '低',
  risk_auto                ENUM('低','中','高') NOT NULL DEFAULT '低',
  risk_override_value      ENUM('低','中','高'),
  risk_override_reason     TEXT,
  risk_override_by         VARCHAR(64),
  risk_override_at         DATETIME,

  -- 报告文档（决策 #11 · 1:1 Issue · 薄壳指外部权威源）
  report_doc_id            VARCHAR(32),

  -- 时间戳
  created_at               DATETIME     NOT NULL,           -- Issue 创建时间（=反馈SLA 计时零点）
  updated_at               DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (id),
  KEY idx_status           (status),                        -- derive.myIssues / myApprovals
  KEY idx_team             (team),                          -- 工作台默认 team 视图
  KEY idx_owner            (owner),                         -- "仅我的" 过滤
  KEY idx_site             (site),
  KEY idx_status_created   (status, created_at),            -- 反馈SLA 派生扫描（决策 #13）
  CONSTRAINT fk_issue_alarm  FOREIGN KEY (source_alarm_id)
            REFERENCES alarm(id)         ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------
-- Issue 创建时一次性 snapshot 的审批链（决策 #5）
-- 组织变动不追溯：snapshot 后不跟随 ref_approval_ladder 变化
-- ---------------------------------------------------------------------
CREATE TABLE issue_approval_chain (
  id          BIGINT       NOT NULL AUTO_INCREMENT,
  issue_id    VARCHAR(32)  NOT NULL,
  level       INT          NOT NULL,
  role        VARCHAR(64)  NOT NULL,
  name        VARCHAR(64)  NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_issue_level (issue_id, level),
  CONSTRAINT fk_iac_issue FOREIGN KEY (issue_id)
            REFERENCES issue(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------
-- Issue 创建时一次性 snapshot 的 PI 名单（决策 #12 · 并行轨道数据）
-- ---------------------------------------------------------------------
CREATE TABLE issue_pi_reviewer (
  issue_id    VARCHAR(32) NOT NULL,
  pi_name     VARCHAR(64) NOT NULL,
  PRIMARY KEY (issue_id, pi_name),
  CONSTRAINT fk_ipr_issue FOREIGN KEY (issue_id)
            REFERENCES issue(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------
-- 受影响批次（必须上会派生规则关键输入：lot.priority==0 + lot.subType ∈ {A,AA,AE}）
-- ---------------------------------------------------------------------
CREATE TABLE issue_affected_lot (
  id          BIGINT       NOT NULL AUTO_INCREMENT,
  issue_id    VARCHAR(32)  NOT NULL,
  lot         VARCHAR(64)  NOT NULL,
  wafers      INT          NOT NULL,
  stage       VARCHAR(64),
  priority    INT          NOT NULL,                        -- 0 = hot lot → 自动 Kanban
  sub_type    ENUM('A','AA','AE','B','C'),                  -- 必须上会派生因子
  PRIMARY KEY (id),
  KEY idx_issue        (issue_id),
  KEY idx_issue_pri    (issue_id, priority),                -- 自动 Kanban 判定扫描
  CONSTRAINT fk_ial_issue FOREIGN KEY (issue_id)
            REFERENCES issue(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------
-- 关联告警（Issue 与上游 alarm 的引用关系 · 仅记录 id+冗余 type/time 供详情显示）
-- ---------------------------------------------------------------------
CREATE TABLE issue_related_alarm (
  issue_id     VARCHAR(32)  NOT NULL,
  alarm_id     VARCHAR(32)  NOT NULL,
  type_snap    VARCHAR(128),                                -- 冗余 snapshot，方便详情展示
  detected_at  DATETIME,
  PRIMARY KEY (issue_id, alarm_id),
  CONSTRAINT fk_ira_issue FOREIGN KEY (issue_id)
            REFERENCES issue(id) ON DELETE CASCADE,
  CONSTRAINT fk_ira_alarm FOREIGN KEY (alarm_id)
            REFERENCES alarm(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------
-- 关键参数 / 量测（Risk 自动判定输入：params.status != '正常' 计数）
-- ---------------------------------------------------------------------
CREATE TABLE issue_param (
  id            BIGINT       NOT NULL AUTO_INCREMENT,
  issue_id      VARCHAR(32)  NOT NULL,
  name          VARCHAR(64)  NOT NULL,
  value         VARCHAR(128) NOT NULL,
  spec          VARCHAR(128),
  status        ENUM('正常','越上限','越下限','超规') NOT NULL,
  PRIMARY KEY (id),
  KEY idx_issue (issue_id),
  CONSTRAINT fk_ip_issue FOREIGN KEY (issue_id)
            REFERENCES issue(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------
-- 附件
-- ---------------------------------------------------------------------
CREATE TABLE issue_attachment (
  id            BIGINT       NOT NULL AUTO_INCREMENT,
  issue_id      VARCHAR(32)  NOT NULL,
  name          VARCHAR(255) NOT NULL,
  size_label    VARCHAR(32),                                -- "212 KB" / "1.1 MB"
  uploaded_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_issue (issue_id),
  CONSTRAINT fk_iat_issue FOREIGN KEY (issue_id)
            REFERENCES issue(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- =====================================================================
-- 4. Meeting / Topic（决策 #7 · 系统自动滚动建早/晚会；topic = junction-with-lifecycle）
-- =====================================================================

CREATE TABLE meeting (
  id          VARCHAR(48)  NOT NULL,                        -- M-AM-2026-06-03 / M-TPC-*
  date        DATE         NOT NULL,
  type        ENUM('早会','晚会','专题','其他') NOT NULL,
  status      ENUM('待召开','已开','取消') NOT NULL DEFAULT '待召开',
  title       VARCHAR(255) NOT NULL,
  created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_date_type   (date, type),                         -- 自动排期目标查找
  KEY idx_status_date (status, date)                        -- 待召开列表 / 月历
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Topic = Issue × Meeting 调度实例。meeting.agenda 是派生视图（topic WHERE meeting_id=…），不另建表
CREATE TABLE topic (
  id            VARCHAR(32)  NOT NULL,                      -- TPC-XXXX
  issue_id      VARCHAR(32)  NOT NULL,
  meeting_id    VARCHAR(48),                                -- NULL = 待排期
  status        ENUM('待汇报','成功','需重排','驳回','移出') NOT NULL DEFAULT '待汇报',
  scheduled_by  ENUM('auto','manual'),
  conclusion    TEXT,
  created_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_issue                    (issue_id),
  KEY idx_meeting                  (meeting_id),
  KEY idx_status_meeting           (status, meeting_id),    -- 待汇报清单 / 待排期
  CONSTRAINT fk_topic_issue   FOREIGN KEY (issue_id)
            REFERENCES issue(id)   ON DELETE CASCADE,
  CONSTRAINT fk_topic_meeting FOREIGN KEY (meeting_id)
            REFERENCES meeting(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- =====================================================================
-- 5. ReportDoc（决策 #11 · 1:1 Issue · 薄壳指向外部权威源）
--    与 Topic 生命周期解耦：议题重排/取消不动 ReportDoc
-- =====================================================================
CREATE TABLE report_doc (
  id              VARCHAR(32)  NOT NULL,                    -- RPT-XXXX
  issue_id        VARCHAR(32)  NOT NULL,
  url             VARCHAR(512),                             -- 外部报告服务地址
  status          ENUM('已生成','生成失败') NOT NULL,
  created_by      ENUM('auto-external','manual-retry') NOT NULL,
  created_at      DATETIME     NOT NULL,
  last_tried_at   DATETIME     NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_issue (issue_id),                           -- 1:1 强约束
  CONSTRAINT fk_rd_issue FOREIGN KEY (issue_id)
            REFERENCES issue(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 反向引用：issue.report_doc_id → report_doc.id（后于 report_doc 建表后加约束）
ALTER TABLE issue
  ADD CONSTRAINT fk_issue_rd FOREIGN KEY (report_doc_id)
      REFERENCES report_doc(id) ON DELETE SET NULL;

-- =====================================================================
-- 6. Event（决策 #6 · 一等公民 · append-only · 生命周期 + 人的决策）
--    routine 字段编辑不进此表（如有需要走通用 audit_log）
-- =====================================================================
CREATE TABLE event (
  id            BIGINT       NOT NULL AUTO_INCREMENT,
  issue_id      VARCHAR(32),                                -- 大部分事件挂 Issue（topic 事件也通过 issue_id 索引）
  topic_id      VARCHAR(32),                                -- 议题相关事件可附 topic_id 便于审计
  type          VARCHAR(64)  NOT NULL,                      -- 创建/提交审批/审批通过/审批打回/PI 评意见/议题汇报成功/Kanban 变更/风险变更/诊断修订/自动建议题/议题重排/手动重试报告/逾期升档/…
  actor         VARCHAR(64)  NOT NULL,                      -- 系统 / 人名 / 角色
  body          TEXT,                                       -- 事件正文（含理由 / 意见 / 摘要）
  is_decision   BOOLEAN      NOT NULL DEFAULT FALSE,        -- decision=true → 详情时间线高亮（紫点）
  occurred_at   DATETIME     NOT NULL,
  PRIMARY KEY (id),
  KEY idx_issue_occurred (issue_id, occurred_at),           -- 详情时间线倒序
  KEY idx_type           (type),                            -- "PI 已评" 等聚合查询
  KEY idx_topic          (topic_id),
  CONSTRAINT fk_ev_issue FOREIGN KEY (issue_id)
            REFERENCES issue(id) ON DELETE CASCADE,
  CONSTRAINT fk_ev_topic FOREIGN KEY (topic_id)
            REFERENCES topic(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- =====================================================================
-- 7. Notification（跨角色通知 · 通知中心数据源）
-- =====================================================================
CREATE TABLE notification (
  id           BIGINT       NOT NULL AUTO_INCREMENT,
  target_role  ENUM('工程师','审批经理','PI','会议主持人','管理员') NOT NULL,
  text         VARCHAR(512) NOT NULL,
  target_id    VARCHAR(48),                                 -- ISS-* / TPC-* / 等
  target_view  VARCHAR(64),                                 -- 通知点击后直达的视图名
  is_read      BOOLEAN      NOT NULL DEFAULT FALSE,
  created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_role_read (target_role, is_read, created_at)      -- 角色未读列表
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- =====================================================================
-- 8. IntegrationSource（接入健康 · 管理员入口的派生看板数据源）
-- =====================================================================
CREATE TABLE integration_source (
  id            VARCHAR(32)  NOT NULL,                      -- SRC-MES / SRC-FDC / SRC-HR
  name          VARCHAR(128) NOT NULL,
  status        ENUM('ok','failed') NOT NULL,
  last_sync_at  DATETIME,
  err_msg       VARCHAR(512),
  PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

SET FOREIGN_KEY_CHECKS = 1;

-- =====================================================================
-- 派生视图说明（无需建表 · SQL 直查）
-- =====================================================================
-- · derive.triageQueue       → SELECT * FROM alarm WHERE status='未分诊'
-- · derive.myIssues          → SELECT * FROM issue WHERE status<>'已关闭'
-- · derive.myApprovals       → SELECT * FROM issue WHERE status='审批中'
-- · derive.scheduledTopics   → SELECT * FROM topic  WHERE status='待汇报' AND meeting_id IS NOT NULL
-- · derive.unscheduledTopics → SELECT * FROM topic  WHERE status='待汇报' AND meeting_id IS NULL
-- · derive.agendaOf(mid)     → SELECT * FROM topic  WHERE meeting_id=:mid
-- · derive.overdue（决策 #13）→ SELECT * FROM issue
--                              WHERE status IN ('处理中','审批中')
--                                AND TIMESTAMPDIFF(HOUR, created_at, NOW()) > 24
-- · derive.myPiPending（决策 #12 PI whose-turn）：
--     SELECT i.* FROM issue i
--     JOIN issue_pi_reviewer r ON r.issue_id = i.id
--    WHERE r.pi_name = :me AND i.status <> '已关闭'
--      AND NOT EXISTS (
--        SELECT 1 FROM event e
--         WHERE e.issue_id = i.id AND e.type = 'PI 评意见' AND e.actor = :me
--      )
-- · 必须上会判定（决策 #9 派生 · 应用层算）：
--     kanban=1
--     AND EXISTS lot WHERE issue_id=i.id AND sub_type IN ('A','AA','AE')
--     AND (chart_level='KIP' OR (chart_level='ACP' AND risk IN ('中','高')))
-- =====================================================================
