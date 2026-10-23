// App texts in Japanese and English. `t` is the current language's set; the settings screen
// switches it (AppSettings.lang), and screens rebuild because they listen to the settings.
// Pure Dart (no Flutter): also compiled to JavaScript for the glasses app (g2/), see lib/standalone/.

const supportedLangs = ['ja', 'en'];

/// [code] (a locale's language code) if supported, else English.
String langOf(String code) => code == 'ja' ? 'ja' : 'en';

L10n _current = const JaText();
L10n get t => _current;
void setLang(String lang) => _current = lang == 'en' ? const EnText() : const JaText();

abstract class L10n {
  const L10n();
  String get lang;
  String get languageName;

  /// Separator between short items (" ・ " in Japanese, " · " in English).
  String get sep;

  // Navigation
  String get tabWalk;
  String get tabLog;
  String get tabSettings;

  // Themes: label, and "what you'll hear" for the settings list
  Map<String, String> get themeLabels;
  Map<String, String> get themeTopics;
  String get defaultCodename;

  // Walk screen
  String get startWalk;
  String get endWalk;
  String get walking;
  String get idle;
  String get callsLabel;
  String callsCount(int n);
  String get devMode;
  String incomingFrom(String commander);
  String townTalk(String spot, String theme);
  String spotTalk(String spot, String theme);
  String get later;
  String get answer;

  // Walk status / notifications
  String get notifTitleChannel;
  String get notifChannelDesc;
  String notifBody(String commander, String spot);
  String get apiKeyInvalid;
  String get apiKeyMissing;
  String get locationOff;
  String get locationPermission;
  String get devModeHint;
  String get standingBy;
  String get foregroundText;
  String get locationUnavailable;
  String researchingNearby(int n);
  String researchingSpot(String spot);
  String researchingTown(String town);
  String get offlineRetry;
  String get areaUnavailable;
  String get savedToLogAuto;
  String get savedToLog;

  // Radio screen
  String photoCredit(String author, String license);
  String sourceChip(int id, String title);
  String get sourcesOfThisTalk;
  String get endCall;

  // Log
  String get logTitle;
  String get noCallsYet;
  String get rangeToday;
  String get rangeWeek;
  String get rangeAll;
  String get unplayed;
  String get playCall;
  String time(DateTime t);
  String heardFrom(String spot, int meters);
  String get sourcesOfThisConversation;

  // AI notice
  String get aiNotice;
  String get aiNoticeTitle;
  String get dontShowAgain;
  String get gotIt;

  // Settings
  String get settingsTitle;
  String get language;
  String get codename;
  String get codenameHelp;
  String get tuneIn;
  String get tuneInHelp;
  String get commanderRow;
  String commanderRowSub(String name, String freq);
  String introOf(String name);
  String get ageTitle;
  String get ageQuestion;
  String get no;
  String get logSection;
  String cacheCount(int n);
  String get clearCache;
  String get clearCacheTitle;
  String get clearCacheBody;
  String get cacheCleared;
  String logCount(int n);
  String get clearLog;
  String get clearLogTitle;
  String get clearLogBody;
  String get delete;
  String get cancel;
  String get logCleared;
  String get yes20;
  String get themeCannotTurnOn;
  String get themeAtLeastOne;
  String get callFrequency;
  String frequencyHelp(int minutes);
  Map<String, String> get frequencyLabels;
  String get claudeApi;
  String get claudeApiHelp;
  String get apiKeyLabel;
  String get saveAndCheck;
  String get keyDeleted;
  String get checking;
  String get keyOk;
  String get keyBad;
  String keyCheckFailed(int status);
  String get networkFailed;
  String spentThisMonth(String usd);
  String get restrictSources;
  String get restrictSourcesHelp;
  String get contact;
  String get contactHelp;
  String get developer;
  String get serverUrl;
  String get serverUrlHelp;
  String get save;
  String get onDevice;
  String serverOk(String provider, String model);
  String get serverOkNoKey;
  String get serverUnreachable;
  String get simulate;
  String get simulateHelp;
  String get walkLog;
  String get walkLogHelp;
  String walkLogCount(int n);
  String get shareWalkLog;
  String get clearWalkLog;
  String get clearWalkLogTitle;
  String get clearWalkLogBody;
  String get walkLogCleared;
  String get privacy;
}

class JaText extends L10n {
  const JaText();
  @override String get lang => 'ja';
  @override String get languageName => '日本語';
  @override String get sep => ' ・ ';

  @override String get tabWalk => '散歩';
  @override String get tabLog => '無線ログ';
  @override String get tabSettings => '設定';

  @override Map<String, String> get themeLabels => const {
        'history': '歴史・史跡', 'architecture': '建築・土木', 'nature': '自然・地形', 'placename': '地名・言葉',
        'film': 'アニメ・映画・音楽', 'tech': 'ガジェット・テック', 'food': '酒・食文化',
      };
  @override Map<String, String> get themeTopics => const {
        'history': '寺社、旧街道、石碑', 'architecture': '橋、駅舎、近代建築', 'nature': '川、坂、地形、公園の木',
        'placename': '町名・坂・橋の名前の由来', 'film': '作品や曲の舞台・ロケ地、映画館、ライブハウス',
        'tech': '技術の発祥、企業、電波塔', 'food': '酒蔵、市場、食の歴史（20歳以上）',
      };
  @override String get defaultCodename => 'ウォーカー';

  @override String get startWalk => '散歩をはじめる';
  @override String get endWalk => '散歩を終える';
  @override String get walking => '散歩中 ';
  @override String get idle => '待機中 ';
  @override String get callsLabel => '無線 ';
  @override String callsCount(int n) => '$n件';
  @override String get devMode => '開発モード';
  @override String incomingFrom(String commander) => '$commanderから無線が入っている';
  @override String townTalk(String spot, String theme) => 'この町の話：$spot$sep$theme';
  @override String spotTalk(String spot, String theme) => '$spot$sep$theme';
  @override String get later => 'あとで';
  @override String get answer => '応答する';

  @override String get notifTitleChannel => '無線の着信';
  @override String get notifChannelDesc => 'スポットの近くで無線が入ったときの通知';
  @override String notifBody(String commander, String spot) => '$commanderから無線が入っている：$spot';
  @override String get apiKeyInvalid => 'ClaudeのAPIキーが使えません（設定画面で確認してください）';
  @override String get apiKeyMissing => 'ClaudeのAPIキーを設定してください（設定画面）';
  @override String get locationOff => '位置情報サービスがオフになっています';
  @override String get locationPermission => '位置情報の権限が必要です';
  @override String get devModeHint => '開発モード：地図を長押しして移動';
  @override String get standingBy => '無線を待機しています';
  @override String get foregroundText => '散歩中：無線を待機しています';
  @override String get locationUnavailable => '位置情報を取得できません';
  @override String researchingNearby(int n) => '近くの$nか所について調べています…';
  @override String researchingSpot(String spot) => '$spot の情報を調べています…';
  @override String researchingTown(String town) => '$town の町について調べています…';
  @override String get offlineRetry => '通信できません（再試行します）';
  @override String get areaUnavailable => '周辺の情報を取得できません（再試行します）';
  @override String get savedToLogAuto => '応答がなかったので、無線ログに保存しました';
  @override String get savedToLog => '無線ログに保存しました';

  @override String photoCredit(String author, String license) => '写真: $author / $license';
  @override String sourceChip(int id, String title) => '出典 [$id] $title';
  @override String get sourcesOfThisTalk => 'この話の出典';
  @override String get endCall => '通信終了';

  @override String get logTitle => '無線ログ';
  @override String get noCallsYet => 'まだ無線はありません';
  @override String get rangeToday => '今日';
  @override String get rangeWeek => '今週';
  @override String get rangeAll => 'すべて';
  @override String get unplayed => '未再生';
  @override String get playCall => '無線を再生';
  @override String time(DateTime d) => '${d.month}月${d.day}日 ${_hm(d)}';
  @override String heardFrom(String spot, int meters) => '受信した場所から$spotまで 約${meters}m';
  @override String get sourcesOfThisConversation => 'この会話の出典';

  @override String get aiNotice => '無線の会話は、AI（Claude）が Web 上の出典をもとに作っています。'
      '内容に不正確な情報が含まれる可能性があります。気になる内容は、会話の最後に表示される出典で確かめてください。';
  @override String get aiNoticeTitle => 'ご利用にあたって';
  @override String get dontShowAgain => '今後は表示しない';
  @override String get gotIt => 'わかりました';

  @override String get settingsTitle => '設定';
  @override String get language => '言語';
  @override String get codename => 'コードネーム';
  @override String get codenameHelp => '無線でこの名前で呼ばれます';
  @override String get tuneIn => '周波数を合わせる';
  @override String get tuneInHelp => '聞きたいテーマを選ぶと、その担当が無線に出ます（いくつでも選べます）。顔をタップすると紹介が見られます';
  @override String get commanderRow => '司令';
  @override String commanderRowSub(String name, String freq) => '$name$sep$freq$sepいつも無線を開く聞き役';
  @override String introOf(String name) => '$nameの紹介';
  @override String get ageTitle => '年齢の確認';
  @override String get ageQuestion => '「酒・食文化」には、お酒の歴史や文化の話が含まれます。20歳以上ですか？';
  @override String get no => 'いいえ';
  @override String get logSection => '保存データ';
  @override String cacheCount(int n) => '保存済みの会話: $n件（同じ場所でもう一度流れるときに使う。30日で作り直し）';
  @override String get clearCache => '会話のキャッシュを消す';
  @override String get clearCacheTitle => '会話のキャッシュを消しますか？';
  @override String get clearCacheBody => '保存済みの会話と、周りの場所の検索結果を消します。無線ログは残ります。次からは会話を作り直すので、新しい会話が聞けますが、そのぶん Claude の利用料がかかり、無線が入るまで少し時間がかかります。';
  @override String get cacheCleared => '会話のキャッシュを消しました';
  @override String logCount(int n) => '保存されている無線: $n件（この端末だけに保存）';
  @override String get clearLog => '無線ログをすべて消す';
  @override String get clearLogTitle => '無線ログを消しますか？';
  @override String get clearLogBody => 'これまでに受けた無線と、地図のピンがすべて消えます。元に戻せません。聞いたことのある場所からも、また初めての無線が入るようになります。会話のキャッシュは残るので、前に聞いたのと同じ会話が流れることがあります（新しい会話にしたいときは、キャッシュも消してください）。';
  @override String get delete => '消す';
  @override String get cancel => 'キャンセル';
  @override String get logCleared => '無線ログを消しました';
  @override String get yes20 => 'はい（20歳以上）';
  @override String get themeCannotTurnOn => 'このテーマはオンにできません';
  @override String get themeAtLeastOne => '最低1つのテーマは必要です';
  @override String get callFrequency => '無線の頻度';
  @override String frequencyHelp(int minutes) => '次の無線まで最低 $minutes 分あけます。同じ場所は1時間たつまで鳴りません。';
  @override Map<String, String> get frequencyLabels => const {'more': '多め', 'normal': '標準', 'less': '少なめ'};
  @override String get claudeApi => 'Claude API';
  @override String get claudeApiHelp => '会話はこの端末から直接 Claude で作ります。ご自身の API キーを入れてください（console.anthropic.com で発行）。'
      'キーは端末の安全な保存領域にだけ保存されます。';
  @override String get apiKeyLabel => 'APIキー（sk-ant-…）';
  @override String get saveAndCheck => '保存して確認';
  @override String get keyDeleted => 'キーを削除しました';
  @override String get checking => '確認中…';
  @override String get keyOk => '使えます（会話は1本あたり数円〜数十円かかります）';
  @override String get keyBad => 'このキーは使えません';
  @override String keyCheckFailed(int status) => '確認できませんでした（$status）';
  @override String get networkFailed => '通信できませんでした';
  @override String spentThisMonth(String usd) => '今月の推定利用料: \$$usd（この端末で作った分）';
  @override String get restrictSources => '出典を Wikipedia と文化庁に限定する';
  @override String get restrictSourcesHelp => 'オフ: 自治体や新聞、観光サイトなども使います。Wikipedia にない場所でも無線が入りやすくなりますが、口コミ系のサイトも混ざります';
  @override String get contact => '連絡先（任意）';
  @override String get contactHelp => 'Wikipedia と OpenStreetMap は、利用者の連絡先（メールやURL）を伝えることを求めています';
  @override String get developer => '開発者向け';
  @override String get serverUrl => 'サーバーURL（空なら端末内で処理）';
  @override String get serverUrlHelp => 'Python 版サーバーと比べるとき用。エミュレーター: http://10.0.2.2:8000';
  @override String get save => '保存';
  @override String get onDevice => '端末内で処理します';
  @override String serverOk(String provider, String model) => '接続OK（会話生成: $provider $model）';
  @override String get serverOkNoKey => '接続OK（会話生成: APIキー未設定）';
  @override String get serverUnreachable => '接続できません';
  @override String get simulate => '開発モード（位置をシミュレート）';
  @override String get simulateHelp => 'GPSの代わりに、散歩画面で地図を長押しした地点を現在地にします。切り替えは散歩を終えてから';
  @override String get walkLog => '散歩ログを記録';
  @override String get walkLogHelp => '改善のために、散歩ごとの移動経路、無線の着信、会話づくりの成功・失敗と API の使用量をこの端末にファイルで残します。外部には送りません。次の散歩から記録します';
  @override String walkLogCount(int n) => '散歩ログ: $n 件';
  @override String get shareWalkLog => '散歩ログを共有';
  @override String get clearWalkLog => '散歩ログをすべて消す';
  @override String get clearWalkLogTitle => '散歩ログを消しますか？';
  @override String get clearWalkLogBody => '記録したすべての散歩ログが消えます。元に戻せません。無線ログと会話のキャッシュは残ります。';
  @override String get walkLogCleared => '散歩ログを消しました';
  @override String get privacy => '無線ログと位置の履歴はこの端末内だけに保存されます。外部に送るのは、近くのスポットを調べるための現在地'
      '（OpenStreetMap・Wikipedia へ）と、調べるスポットの名前・場所（Claude へ）だけです。';
}

class EnText extends L10n {
  const EnText();
  @override String get lang => 'en';
  @override String get languageName => 'English';
  @override String get sep => ' · ';

  @override String get tabWalk => 'Walk';
  @override String get tabLog => 'Radio log';
  @override String get tabSettings => 'Settings';

  @override Map<String, String> get themeLabels => const {
        'history': 'History & heritage', 'architecture': 'Architecture & engineering', 'nature': 'Nature & terrain',
        'placename': 'Place names & words', 'film': 'Anime, film & music', 'tech': 'Gadgets & tech',
        'food': 'Sake & food culture',
      };
  @override Map<String, String> get themeTopics => const {
        'history': 'Shrines, temples, old highways, monuments', 'architecture': 'Bridges, stations, modern buildings',
        'nature': 'Rivers, slopes, terrain, park trees', 'placename': 'Where town, slope and bridge names come from',
        'film': 'Film, anime and song locations, cinemas, live venues', 'tech': 'Where tech began, companies, radio towers',
        'food': 'Breweries, markets, food history (20+)',
      };
  @override String get defaultCodename => 'Walker';

  @override String get startWalk => 'Start walk';
  @override String get endWalk => 'End walk';
  @override String get walking => 'Walking ';
  @override String get idle => 'Idle ';
  @override String get callsLabel => 'Calls ';
  @override String callsCount(int n) => '$n';
  @override String get devMode => 'Dev mode';
  @override String incomingFrom(String commander) => 'Incoming call from $commander';
  @override String townTalk(String spot, String theme) => 'About this town: $spot · $theme';
  @override String spotTalk(String spot, String theme) => '$spot · $theme';
  @override String get later => 'Later';
  @override String get answer => 'Answer';

  @override String get notifTitleChannel => 'Incoming calls';
  @override String get notifChannelDesc => 'When a radio call comes in near a spot';
  @override String notifBody(String commander, String spot) => 'Incoming call from $commander: $spot';
  @override String get apiKeyInvalid => 'Your Claude API key does not work (check Settings)';
  @override String get apiKeyMissing => 'Set your Claude API key (Settings)';
  @override String get locationOff => 'Location services are off';
  @override String get locationPermission => 'Location permission is needed';
  @override String get devModeHint => 'Dev mode: long-press the map to move';
  @override String get standingBy => 'Standing by for calls';
  @override String get foregroundText => 'Walking: standing by for calls';
  @override String get locationUnavailable => 'Cannot get your location';
  @override String researchingNearby(int n) => 'Looking into $n places nearby…';
  @override String researchingSpot(String spot) => 'Looking into $spot…';
  @override String researchingTown(String town) => 'Looking into the town of $town…';
  @override String get offlineRetry => 'No connection (retrying)';
  @override String get areaUnavailable => 'Cannot get the area info (retrying)';
  @override String get savedToLogAuto => 'No answer, so it went to the radio log';
  @override String get savedToLog => 'Saved to the radio log';

  @override String photoCredit(String author, String license) => 'Photo: $author / $license';
  @override String sourceChip(int id, String title) => 'Source [$id] $title';
  @override String get sourcesOfThisTalk => 'Sources';
  @override String get endCall => 'End call';

  @override String get logTitle => 'Radio log';
  @override String get noCallsYet => 'No calls yet';
  @override String get rangeToday => 'Today';
  @override String get rangeWeek => 'This week';
  @override String get rangeAll => 'All';
  @override String get unplayed => 'Unplayed';
  @override String get playCall => 'Play the call';
  @override String time(DateTime d) => '${const ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][d.month]} ${d.day}, ${_hm(d)}';
  @override String heardFrom(String spot, int meters) => 'Heard about ${meters}m from $spot';
  @override String get sourcesOfThisConversation => 'Sources of this conversation';

  @override String get aiNotice => 'Radio conversations are written by AI (Claude) from sources on the web. '
      'They may contain inaccurate information. Check the sources shown at the end of each call if something matters to you.';
  @override String get aiNoticeTitle => 'Before you start';
  @override String get dontShowAgain => "Don't show this again";
  @override String get gotIt => 'Got it';

  @override String get settingsTitle => 'Settings';
  @override String get language => 'Language';
  @override String get codename => 'Codename';
  @override String get codenameHelp => 'The radio calls you by this name';
  @override String get tuneIn => 'Tune in';
  @override String get tuneInHelp => 'Pick the topics you want; their specialists will call you (as many as you like). Tap a face to meet them';
  @override String get commanderRow => 'Commander';
  @override String commanderRowSub(String name, String freq) => '$name · $freq · always opens the call';
  @override String introOf(String name) => 'About $name';
  @override String get ageTitle => 'Age check';
  @override String get ageQuestion => '"Sake & food culture" includes the history and culture of alcohol. Are you 20 or older?';
  @override String get no => 'No';
  @override String get logSection => 'Saved data';
  @override String cacheCount(int n) => 'Cached conversations: $n (reused when a place calls again; rewritten after 30 days)';
  @override String get clearCache => 'Delete the conversation cache';
  @override String get clearCacheTitle => 'Delete the conversation cache?';
  @override String get clearCacheBody => 'Cached conversations and nearby place lookups will be deleted. The call log stays. Conversations will be written again: you hear new ones, but it costs Claude usage and calls take a little longer to come in.';
  @override String get cacheCleared => 'Conversation cache deleted';
  @override String logCount(int n) => 'Saved calls: $n (stored only on this phone)';
  @override String get clearLog => 'Delete the whole call log';
  @override String get clearLogTitle => 'Delete the call log?';
  @override String get clearLogBody => 'Every call you received and every map pin will be deleted. This cannot be undone. Places you have heard will call again as if for the first time. The conversation cache stays, so you may hear the same conversation again (delete the cache too for new ones).';
  @override String get delete => 'Delete';
  @override String get cancel => 'Cancel';
  @override String get logCleared => 'Call log deleted';
  @override String get yes20 => 'Yes (20+)';
  @override String get themeCannotTurnOn => 'This topic cannot be turned on';
  @override String get themeAtLeastOne => 'Keep at least one topic on';
  @override String get callFrequency => 'Call frequency';
  @override String frequencyHelp(int minutes) => 'At least $minutes minutes between calls. The same place stays quiet for an hour.';
  @override Map<String, String> get frequencyLabels => const {'more': 'More', 'normal': 'Normal', 'less': 'Fewer'};
  @override String get claudeApi => 'Claude API';
  @override String get claudeApiHelp => 'Conversations are made on this phone with Claude. Enter your own API key (from console.anthropic.com). '
      'It is stored only in the phone\'s secure storage.';
  @override String get apiKeyLabel => 'API key (sk-ant-…)';
  @override String get saveAndCheck => 'Save and check';
  @override String get keyDeleted => 'Key removed';
  @override String get checking => 'Checking…';
  @override String get keyOk => 'Works (each conversation costs a few cents)';
  @override String get keyBad => 'This key does not work';
  @override String keyCheckFailed(int status) => 'Could not check ($status)';
  @override String get networkFailed => 'Network error';
  @override String spentThisMonth(String usd) => 'Estimated spend this month: \$$usd (on this phone)';
  @override String get restrictSources => 'Only use Wikipedia and the Agency for Cultural Affairs';
  @override String get restrictSourcesHelp => 'Off: also uses city sites, news and travel sites. More places get calls, but review-type sites may be mixed in';
  @override String get contact => 'Contact (optional)';
  @override String get contactHelp => 'Wikipedia and OpenStreetMap ask apps to include a contact (email or URL)';
  @override String get developer => 'Developer';
  @override String get serverUrl => 'Server URL (empty = on this phone)';
  @override String get serverUrlHelp => 'For comparing with the Python server. Emulator: http://10.0.2.2:8000';
  @override String get save => 'Save';
  @override String get onDevice => 'Runs on this phone';
  @override String serverOk(String provider, String model) => 'Connected (dialogues: $provider $model)';
  @override String get serverOkNoKey => 'Connected (no API key on the server)';
  @override String get serverUnreachable => 'Cannot connect';
  @override String get simulate => 'Dev mode (simulate location)';
  @override String get simulateHelp => 'Instead of GPS, long-press the map on the walk screen to set your position. Switch after ending a walk';
  @override String get walkLog => 'Keep a walk log';
  @override String get walkLogHelp => 'To help improve the app, keeps a file on this phone for each walk: your route, the calls, whether each conversation was written or failed, and the API usage. Nothing is sent anywhere. Starts with the next walk';
  @override String walkLogCount(int n) => 'Walk logs: $n';
  @override String get shareWalkLog => 'Share the walk logs';
  @override String get clearWalkLog => 'Delete all walk logs';
  @override String get clearWalkLogTitle => 'Delete the walk logs?';
  @override String get clearWalkLogBody => 'Every walk log will be deleted. This cannot be undone. The call log and the conversation cache stay.';
  @override String get walkLogCleared => 'Walk logs deleted';
  @override String get privacy => 'Your radio log and location history stay on this phone. Only your current position (to OpenStreetMap and Wikipedia, '
      'to find nearby spots) and the names and locations of spots being researched (to Claude) leave it.';
}

String _hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
