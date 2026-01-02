# マネーフォワード 自動更新スクリプト

マネーフォワードに登録している金融機関の情報を自動で更新するRubyスクリプトです。

## 必要な環境

- Ruby 2.7以上
- Google Chrome
- ChromeDriver（自動的にインストールされます）

## セットアップ

### 1. 依存関係のインストール

```bash
bundle install
```

### 2. 環境変数の設定

`.env.example` をコピーして `.env` ファイルを作成し、マネーフォワードのログイン情報を設定してください。

```bash
cp .env.example .env
```

`.env` ファイルを編集：

```env
MONEYFORWARD_EMAIL=your-email@example.com
MONEYFORWARD_PASSWORD=your-password
HEADLESS=true
```

## 使用方法

### 環境変数を使用する場合（推奨）

```bash
ruby moneyforward_updater.rb
```

### コマンドライン引数を使用する場合

```bash
ruby moneyforward_updater.rb your-email@example.com your-password
```

### ブラウザを表示して実行する場合

デバッグ時などにブラウザの動作を確認したい場合は、環境変数 `HEADLESS=false` を設定します。

```bash
HEADLESS=false ruby moneyforward_updater.rb
```

## 機能

- マネーフォワードへの自動ログイン
- 登録されているすべての金融機関の自動更新
- 更新状況のログ出力
- エラーハンドリング
- **ブラウザプロファイル永続化**: 一度ログインすると、次回からは追加認証なしで実行可能

## 追加認証の回避について

このスクリプトは、Chromeのユーザーデータディレクトリ（`~/.moneyforward_chrome_profile`）を使用してブラウザの状態を永続化します。これにより、一度ログインして追加認証を完了すると、次回以降は同じデバイスとして認識され、追加認証を求められることなく自動実行が可能になります。

**初回実行時の手順:**
1. `HEADLESS=false` でブラウザを表示して実行
2. 追加認証コードが表示されたら、手動で入力（15秒の待機時間内に入力）
3. 次回以降は追加認証なしで実行可能

```bash
# 初回実行（ブラウザ表示、認証コード入力が必要）
HEADLESS=false ruby moneyforward_updater.rb

# 2回目以降（認証コード不要、ヘッドレスモードでも可）
ruby moneyforward_updater.rb
```

**重要:** User-Agentとブラウザプロファイルを固定することで、マネーフォワードに「いつもお使いのデバイス」として認識させています。初回のみ追加認証コードの入力が必要ですが、2回目以降は自動的にログイン状態が復元されます。

## 注意事項

- このスクリプトはマネーフォワードのWeb版を操作します
- ログイン情報は安全に管理してください（`.env` ファイルはgitignoreに含まれています）
- ブラウザプロファイルは `~/.moneyforward_chrome_profile` に保存されます
- マネーフォワードの仕様変更により動作しなくなる可能性があります
- 頻繁な実行は避け、適切な間隔で実行してください

## トラブルシューティング

### ChromeDriverのエラーが出る場合

Selenium 4.6以降では、ChromeDriverは自動的に管理されます。もしエラーが出る場合は、Chromeブラウザを最新版に更新してください。

### ログインできない場合

- メールアドレスとパスワードが正しいか確認してください
- 二段階認証が有効になっていないか確認してください
- `HEADLESS=false` を設定してブラウザの動作を確認してください

### 更新ボタンが見つからない場合

マネーフォワードのページ構造が変更された可能性があります。`HEADLESS=false` を設定して実際のページを確認してください。

### 毎回追加認証を求められる場合

ブラウザプロファイルが正しく保存されていない可能性があります：

1. `~/.moneyforward_chrome_profile` ディレクトリを削除して、再度初回セットアップを実行してください
   ```bash
   rm -rf ~/.moneyforward_chrome_profile
   HEADLESS=false ruby moneyforward_updater.rb
   ```

2. 初回実行時は必ず `HEADLESS=false` で実行し、追加認証コードを15秒以内に入力してください

3. 環境変数 `USER_AGENT` を設定して、User-Agentを固定することもできます

## ライセンス

MIT
