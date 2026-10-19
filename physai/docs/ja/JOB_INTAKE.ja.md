# ジョブインテーク

外部システムがクラスターにパイプライン実行を送信し、完了時に通知を受け取れるようにします。最初の呼び出し元は [VAMS](https://github.com/awslabs/visual-asset-management-system) で、アセットのデータに対して学習実行を送信し、生成されたチェックポイントを取り込みます。現時点でスタックがデプロイするのは、ログインノードに到達するトランスポートです。実装済みの内容は [STATUS.ja.md](STATUS.ja.md) を参照してください。

ジョブインテークは**オプトイン**です。呼び出し元を設定するまで何もデプロイされません。手動の経路 (ログインノード上の `physai run`。[PHYSAI_CLI.ja.md](PHYSAI_CLI.ja.md) を参照) は変わりません。

## 全体像

```
このアカウント
──────────────
 submit Lambda ── クラスター VPC 経由の SSH ──► HyperPod ログインノード
```

## 有効化

許可する呼び出し元を `infra/cdk.json` に列挙します。このリストがスイッチです。呼び出し元がなければスタックは作成されません。

```json
{
  "context": {
    "jobIntakeCallers": [
      { "accountId": "111122223333" },
      { "accountId": "444455556666", "roleNamePattern": "vams-prod-*-pask-integration" }
    ]
  }
}
```

その後、通常どおりデプロイします:

```bash
cd infra
npx cdk deploy --all
```

`jobIntakeCallers` は `-c` ではなく `cdk.json` で設定する必要があります。CDK CLI はすべての `-c` の値を文字列のまま渡すため、配列でなければ synth が失敗します。

| 呼び出し元のフィールド | 必須 | デフォルト | 備考 |
|---|---|---|---|
| `accountId` | はい | — | 12 桁の AWS アカウント ID |
| `roleNamePattern` | いいえ | `*-pask-integration` | 呼び出し元のすべてのロールが一致すべき、`*` と `?` のワイルドカードを使えるロール名のパターン。ワイルドカードだけのパターンは拒否されます。ロールに解決するのではなくロールの ARN にパターンとして照合するため、削除して作り直したロールも引き続き使えます |

アカウント ID が 12 桁でない場合や重複して記載されている場合、またロール名のパターンが不正な場合やワイルドカードだけの場合は synth が失敗します。

### 無効化

先に `PhysaiJobIntakeStack` を削除してから `jobIntakeCallers` を空にしてデプロイします。逆の順序では失敗します。`PhysaiClusterStack` はジョブインテークのスタックがインポートする値をエクスポートしており、CloudFormation は使用中のエクスポートを削除しません。同じ理由で、`PhysaiClusterStack` を削除すると `PhysaiJobIntakeStack` も一緒に削除されます。

### ログインノードの SSH 鍵

スタックは submit Lambda 用に ED25519 のキーペアを生成します。ログインノードのライフサイクルスクリプト `install_job_intake_key.sh` が、ログインノードの作成時と置き換え時にその公開鍵を `ubuntu` にインストールするため、置き換えられたノードにも自動的に入ります。再起動ではスクリプトは再実行されません。

ジョブインテークを有効にした時点ですでに稼働していたクラスターでは、最初のデプロイ後に一度だけ実行してください:

```bash
infra/scripts/run-lifecycle.sh --group login-group --script install_job_intake_key.sh
```

スクリプトは、ジョブインテークが有効でキーペアが検証に通った場合にのみ鍵をインストールし、それ以外の場合は以前にインストールした鍵を削除します:

- キーペアは、`PhysaiJobIntakeStack` が出力値 `SshKeyPairId` として公開する ID のものである必要があります。同じ名前で手作業で作り直したキーペアは ID が変わるため拒否され、出力値を変えるにはスタックの更新が必要です
- ED25519 の鍵で、公開鍵が整形式の 1 行である必要があります。これにより、API から `authorized_keys` のオプションが追加されることはありません
- インストールされる行は `restrict,from="10.0.0.0/16" ssh-ed25519 ... job-intake:<name>` です。VPC 内からのみ使用でき、転送と pty の割り当ては無効です。ファイル内の他の鍵には触れません
- 一時的な参照エラーの場合、ファイルはそのまま残ります
- ファイルは `ubuntu` として書き込まれるため、スクリプトがそのユーザーのホームに置かれたリンクをたどることはありません
- スクリプトがノードのライフサイクルを失敗させることはありません。失敗はログに残り、スクリプトが再実行されるまでジョブインテークはそのノードに到達できません

## デプロイされるもの

`PhysaiJobIntakeStack`。[`infra/lib/job-intake-stack.ts`](../../infra/lib/job-intake-stack.ts) で定義されています。リソース名はサフィックスなしの `clusterName` から導出されるため、`PhysaiClusterStack` の再デプロイ後も維持されます。以下の `<clusterName>` はこのサフィックスなしの名前です。ただし `<clusterName>-ExecutionRole` は `PhysaiClusterStack` のリソースで、サフィックスが付きます。

### ログインノードの SSH キーペア

- `<clusterName>-job-intake`。タイプ ED25519 の `AWS::EC2::KeyPair`
- 秘密鍵は CloudFormation が SSM Parameter Store に SecureString として保存し、submit Lambda のメモリ上でのみ扱われます
- スタックを削除すると秘密鍵を含めて鍵が削除されます。公開鍵は次のライフサイクル実行時にログインノードから削除されます

### submit Lambda

`<clusterName>-job-intake-submit`: Python 3.12 の zip、arm64、512 MB、タイムアウト 5 分。

- クラスター VPC のプライベートサブネットにアタッチされ、専用のセキュリティグループを持ち、クラスターのセキュリティグループに `tcp/22` のインバウンドルールを 1 つだけ追加します
- HyperPod はノードを置き換えるため、呼び出しのたびに `sagemaker:ListClusterNodes` でログインノードの `PrivateDnsHostname` を解決します
- paramiko で `ubuntu` として接続します。接続のタイムアウトは 20 秒、コマンドごとに 60 秒で、起動が関数のタイムアウト内に十分収まります。置き換えられたノードはホスト鍵が変わるため、ホスト鍵は固定しません

| ペイロード | 動作 |
|---|---|
| `{"probeOnly": true}` | セッションを開き、`hostname; whoami; sinfo` を実行します |

**バンドル。** CDK は `Code.fromCustomCommand` を通じてホスト上で [`infra/lambda/build.py`](../../infra/lambda/build.py) を実行します。Docker は不要です。

- 依存関係は `uv pip install --python-platform aarch64-unknown-linux-gnu --only-binary :all:` で Lambda のプラットフォーム向けにインストールされるため、wheel が欠けている場合はホスト向けにコンパイルせずビルドが失敗します
- zip は固定のタイムスタンプとモード、ソート済みのエントリで書き込まれるため、ソースが変わらなければアセットハッシュも変わらず、再デプロイされません
- デプロイするマシンに `uv` と `python3` が必要です

### IAM

- **submit Lambda**: 鍵のパラメータに対する `ssm:GetParameter`、`kms:ViaService: ssm.<region>.amazonaws.com` 条件付きの `kms:Decrypt`、`sagemaker:ListClusterNodes`、`AWSLambdaVPCAccessExecutionRole`
- **`<clusterName>-ExecutionRole`** (このスタックが拡張): `install_job_intake_key.sh` 用の、このスタックに対する `cloudformation:DescribeStacks` と `ec2:DescribeKeyPairs`。EC2 は後者を特定のキーペアに限定できないため `*` に付与し、スクリプトはスタックが公開する ID だけを信頼します

### 出力値

| 出力値 | 用途 |
|---|---|
| `SubmitFunctionName` | トランスポートを確認します |
| `SshKeyName` | ログインノードにインストールするキーペア |
| `SshKeyPairId` | ログインノードが信頼するキーペア (ID) |

## 検証方法

トランスポートを確認します:

```bash
aws lambda invoke --function-name <SubmitFunctionName> \
  --payload '{"probeOnly": true}' --cli-binary-format raw-in-base64-out \
  /dev/stdout | jq .
```

| 結果 | 意味 |
|---|---|
| `ok: true` で、`stdout` に `sinfo` のパーティションが表示される | 経路全体が機能しています |
| `reason: authenticationFailed` | ネットワーク経路は機能しています。鍵がインストールされていません。上記のとおり `install_job_intake_key.sh` を実行し、出力を確認してください |
| `no route to <host>:22` | VPC アタッチ、`tcp/22` ルール、または起動途中のログインノード |
| `no Running node in instance group ...` | クラスターに稼働中のログインノードがありません |
| `ssm:GetParameter` での `AccessDenied` | submit Lambda の IAM |

## 関連ドキュメント

- [INFRA.ja.md](INFRA.ja.md) — CDK スタック
- [PHYSAI_CLI.ja.md](PHYSAI_CLI.ja.md) — 手動の経路
