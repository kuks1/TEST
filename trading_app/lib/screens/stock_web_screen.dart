import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class StockWebScreen extends StatefulWidget {
  final String ticker;
  final String name;
  final String market;

  const StockWebScreen({
    super.key,
    required this.ticker,
    required this.name,
    required this.market,
  });

  @override
  State<StockWebScreen> createState() => _StockWebScreenState();
}

class _StockWebScreenState extends State<StockWebScreen> {
  String get _url {
    if (widget.market == 'KR') {
      return 'https://finance.naver.com/item/main.nhn?code=${widget.ticker}';
    }
    return 'https://finance.yahoo.com/quote/${widget.ticker}';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await launchUrl(Uri.parse(_url), mode: LaunchMode.externalApplication);
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.name,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            Text(widget.ticker,
                style: const TextStyle(fontSize: 10, color: Color(0xFF8B949E))),
          ],
        ),
      ),
      body: const Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircularProgressIndicator(strokeWidth: 2),
          SizedBox(height: 16),
          Text('브라우저에서 열기 중...',
              style: TextStyle(color: Color(0xFF8B949E), fontSize: 13)),
        ]),
      ),
    );
  }
}
