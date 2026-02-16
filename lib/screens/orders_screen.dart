import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../l10n/generated/app_localizations.dart';
import '../models/payment_method.dart';
import '../models/plan.dart';
import '../services/v2board_api.dart';
import '../theme/app_colors.dart';
import '../widgets/glow_button.dart';
import '../widgets/gradient_card.dart';
import '../widgets/section_header.dart';
import '../widgets/flux_loader.dart';

import 'order_success_screen.dart';

class OrdersScreen extends StatefulWidget {
  final Plan? selectedPlan;
  final VoidCallback? onPickPlan;
  final VoidCallback? onPaid;
  const OrdersScreen({
    super.key,
    this.selectedPlan,
    this.onPickPlan,
    this.onPaid,
  });

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  final _api = V2BoardApi();
  final _couponController = TextEditingController();
  String _period = 'month_price';
  bool _loading = false;
  PaymentMethod? _method;
  String? _message;
  Future<List<PaymentMethod>>? _methodsFuture;
  List<PaymentMethod>? _cachedMethods;

  bool _isPolling = false;

  @override
  void initState() {
    super.initState();
    _loadMethodsData();
    final allowed = _availablePeriods(widget.selectedPlan);
    _period = allowed.isNotEmpty ? allowed.first : 'month_price';
  }

  @override
  void didUpdateWidget(covariant OrdersScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedPlan?.id != widget.selectedPlan?.id) {
      final allowed = _availablePeriods(widget.selectedPlan);
      if (!allowed.contains(_period)) {
        setState(() {
          _period = allowed.isNotEmpty ? allowed.first : 'month_price';
        });
      }
    }
  }

  List<String> _availablePeriods(Plan? plan) {
    if (plan == null) return const ['month_price'];
    final items = <String>[];
    // 显示所有周期选项，即使价格为0也显示（允许免费套餐）
    if (plan.monthPrice != null) items.add('month_price');
    if (plan.quarterPrice != null) items.add('quarter_price');
    if (plan.halfYearPrice != null) items.add('half_year_price');
    if (plan.yearPrice != null) items.add('year_price');
    if (plan.twoYearPrice != null) items.add('two_year_price');
    if (plan.threeYearPrice != null) items.add('three_year_price');
    if (plan.onetimePrice != null) items.add('onetime_price');
    if (plan.resetPrice != null) items.add('reset_price');
    return items.isEmpty ? const ['month_price'] : items;
  }

  String _periodLabel(String value) {
    final l10n = AppLocalizations.of(context);
    switch (value) {
      case 'month_price':
        return l10n?.monthPrice ?? '按月';
      case 'quarter_price':
        return l10n?.quarterPrice ?? '按季';
      case 'half_year_price':
        return l10n?.halfYearPrice ?? '半年';
      case 'year_price':
        return l10n?.yearPrice ?? '按年';
      case 'two_year_price':
        return l10n?.twoYearPrice ?? '两年';
      case 'three_year_price':
        return l10n?.threeYearPrice ?? '三年';
      case 'onetime_price':
        return l10n?.onetimePrice ?? '一次性';
      case 'reset_price':
        return l10n?.resetPrice ?? '重置流量';
      default:
        return value;
    }
  }



  void _loadMethodsData() {
    _methodsFuture = _loadMethods().then((methods) {
      if (mounted) {
        _cachedMethods = methods;
      }
      return methods;
    });
  }

  @override
  void dispose() {
    _couponController.dispose();
    super.dispose();
  }

  Future<List<PaymentMethod>> _loadMethods() async {
    final data = await _api.getPaymentMethods();
    final list = (data['data'] as List? ?? [])
        .map((item) => PaymentMethod.fromJson(item as Map<String, dynamic>))
        .toList();
    return list;
  }

  Future<void> _createOrder() async {
    final plan = widget.selectedPlan;
    if (plan == null) {
      setState(() => _message = AppLocalizations.of(context)?.selectPlanFirst ?? 'Please select a plan first');
      return;
    }
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      // 1. 创建订单
      final data = await _api.saveOrder(
        plan.id,
        _period,
        couponCode: _couponController.text.trim().isEmpty ? null : _couponController.text.trim(),
      );
      final tradeNo = data['data']?.toString();
      if (tradeNo == null || tradeNo.isEmpty) {
        if (mounted) {
          setState(() => _message = AppLocalizations.of(context)?.orderCreationFail ?? 'Order creation failed');
        }
        return;
      }
      
      // 自动发起支付流程
      await _checkoutOrder(tradeNo, _method?.id);
    } catch (e) {
      // 检查是否是有未支付订单的错误
      final errorMsg = e.toString();
      String? unpaidTradeNo = _extractUnpaidTradeNo(errorMsg);
      
      // 如果报错不仅没有单号，但明确提示有未支付订单，我们需要主动去获取
      if (unpaidTradeNo == 'UNKNOWN') {
        try {
          // 主动获取订单列表寻找未支付订单
          final ordersData = await _api.fetchOrders();
          final orders = ordersData['data'] as List?;
          if (orders != null && orders.isNotEmpty) {
            // 找状态为0 (待支付) 的订单
            final pending = orders.firstWhere(
              (o) => o['status'] == 0,
              orElse: () => null,
            );
            if (pending != null) {
              unpaidTradeNo = pending['trade_no'];
            }
          }
        } catch (_) {
          // ignore
        }
      }
      
      if (unpaidTradeNo != null && unpaidTradeNo != 'UNKNOWN' && mounted) {
        // 显示继续支付/取消订单对话框
        await _showUnpaidOrderDialog(unpaidTradeNo);
      } else if (mounted) {
        setState(() => _message = '${AppLocalizations.of(context)?.purchaseFailed ?? "Purchase failed"}: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }
  
  /// 从错误信息中提取未支付订单号
  String? _extractUnpaidTradeNo(String errorMsg) {
    // 尝试匹配订单号格式（通常是数字）
    final regex = RegExp(r'(\d{18,})');
    final match = regex.firstMatch(errorMsg);
    if (match != null) {
      return match.group(1);
    }
    // 检查中文关键词
    if (errorMsg.contains('待支付') || 
        errorMsg.contains('未支付') || 
        errorMsg.contains('未付款') || // 用户遇到的提示
        errorMsg.contains('开通中') || 
        errorMsg.contains('unpaid')) {
      return 'UNKNOWN';
    }
    return null;
  }
  
  /// 显示未支付订单处理对话框
  Future<void> _showUnpaidOrderDialog(String tradeNo) async {
    final isUnknown = tradeNo == 'UNKNOWN';
    
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          AppLocalizations.of(context)?.unpaidOrder ?? 'Unpaid Order',
          style: const TextStyle(color: Colors.white, fontSize: 18),
        ),
        content: Text(
          AppLocalizations.of(context)?.unpaidOrderMessage ?? 'You have an unpaid order. Please continue to pay or cancel.',
          style: TextStyle(color: Colors.white.withOpacity(0.8)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: Text(
              AppLocalizations.of(context)?.cancelOrder ?? 'Cancel Order',
              style: TextStyle(color: Colors.red.shade400),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'continue'),
            child: Text(
              AppLocalizations.of(context)?.continuePayment ?? 'Continue Payment',
              style: const TextStyle(color: AppColors.accent),
            ),
          ),
        ],
      ),
    );
    
    if (result == 'cancel' && !isUnknown) {
      // 取消订单
      await _cancelOrder(tradeNo);
    } else if (result == 'continue' && !isUnknown) {
      // 继续支付
      await _checkoutOrder(tradeNo, _method?.id);
    }
  }
  
  /// 取消订单
  Future<void> _cancelOrder(String tradeNo) async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _message = AppLocalizations.of(context)?.cancelingOrder ?? 'Canceling order...';
    });
    try {
      await _api.cancelOrder(tradeNo);
      if (mounted) {
        setState(() => _message = AppLocalizations.of(context)?.orderCanceled ?? 'Order canceled, please buy again');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _message = '取消订单失败: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _checkoutOrder(String tradeNo, int? methodId) async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _message = AppLocalizations.of(context)?.submittingOrder ?? 'Submitting order...';
    });
    try {
      // 1. 提交支付请求
      final result = await _api.checkoutOrder(tradeNo, methodId ?? 0);
      
      // 2. 检查提交结果
      final data = result['data'];

      // 请求完成后立即取消 loading，避免按钮一直转圈
      if (mounted) {
        setState(() => _loading = false);
      }
      
      // 如果返回的是 URL，直接跳转支付
      if (data is String && (data.startsWith('http') || data.startsWith('alipays://') || data.startsWith('weixin://'))) {
         final uri = Uri.parse(data);
         if (await canLaunchUrl(uri)) {
           await launchUrl(uri, mode: LaunchMode.externalApplication);
         } else {
           throw Exception(AppLocalizations.of(context)?.cannotOpenPaymentLink ?? 'Cannot open payment link');
         }
      } else {
        // 余额支付或其他同步支付方式
        final success = data == true || data == 1;
        if (!success) {
           // 检查 type，有些接口 type -1 表示错误
           throw Exception(AppLocalizations.of(context)?.paymentRequestFailed ?? 'Payment request failed');
        }
      }

      // 3. 开始轮询检查订单状态(后台执行)
      _startPolling(tradeNo);

    } catch (e) {
      if (mounted) {
        setState(() {
           _message = '${AppLocalizations.of(context)?.paymentException ?? "Payment exception"}: $e';
           _loading = false;
        });
      }
    }
  }

  Future<void> _startPolling(String tradeNo) async {
      if (_isPolling || !mounted) return;
      _isPolling = true;

      if (mounted) {
        setState(() => _message = AppLocalizations.of(context)?.confirmPaymentResult ?? 'Checking payment result...');
      }

      const maxRetries = 60; // 最多轮询 60 次
      const interval = Duration(seconds: 1);
      bool orderPaid = false;

      try {
        for (var i = 0; i < maxRetries; i++) {
          if (!mounted) break;
          
          final checkRes = await _api.checkOrder(tradeNo);
          // API 返回: {"data":1} 表示已支付/开通成功; {"data":0} 表示未支付
          final status = checkRes['data'];
          print('Order check status: $status (${status.runtimeType})');
          
          if (status == 1 || status == true || status == '1' || status == 3 || status == '3') {
            orderPaid = true;
            break;
          }

          await Future.delayed(interval);
        }

        if (mounted) {
          if (orderPaid) {
            setState(() {
              _message = AppLocalizations.of(context)?.orderSuccess ?? 'Order Successful!';
            });
            if (mounted) {
              widget.onPaid?.call();
              
              // 跳转到成功页面
              final result = await Navigator.push<bool>(
                context,
                MaterialPageRoute(
                  builder: (context) => OrderSuccessScreen(
                    plan: widget.selectedPlan!,
                    period: _period,
                    tradeNo: tradeNo,
                  ),
                ),
              );
              
              if (mounted && result == true) {
                Navigator.of(context).pop(true);
              }
            }
          } else {
            setState(() {
              _message = AppLocalizations.of(context)?.paymentResultTimeout ?? 'Payment timeout, check history later';
            });
          }
        }
      } catch (e) {
        if (mounted) {
           setState(() => _message = '${AppLocalizations.of(context)?.queryStatusFailed ?? "Status query failed"}: $e');
        }
      } finally {
        _isPolling = false;
      }
  }



  @override
  Widget build(BuildContext context) {
    final methodsFuture = _methodsFuture ??= _loadMethods().then((methods) {
      if (mounted) {
        _cachedMethods = methods;
      }
      return methods;
    });
    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context)?.payment ?? 'Payment'),
      ),
      body: DecoratedBox(
        decoration: const BoxDecoration(gradient: AppColors.heroGlow),
        child: FutureBuilder<List<PaymentMethod>>(
          future: methodsFuture,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              final err = snapshot.error;
              final message =
                  err is V2BoardApiException ? err.message : (AppLocalizations.of(context)?.networkError ?? 'Network error');
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      message,
                      style: const TextStyle(color: AppColors.accentWarm),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _cachedMethods = null;
                          _loadMethodsData();
                        });
                      },
                      child: Text(AppLocalizations.of(context)?.retry ?? 'Retry'),
                    ),
                  ],
                ),
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: FluxLoader(showTips: true));
            }
            final methods = snapshot.data ?? [];
            if (methods.isNotEmpty && _method == null) {
              _method = methods.first;
            }
            final periods = _availablePeriods(widget.selectedPlan);
            return ListView(
              padding: const EdgeInsets.all(20),
              children: [
                SectionHeader(title: AppLocalizations.of(context)?.orderAndPay ?? 'Order & Pay'),
                const SizedBox(height: 12),
                if (widget.selectedPlan == null) ...[
                  GradientCard(
                    child: Row(
                      children: [
                        const Icon(Icons.layers, color: AppColors.accent),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            AppLocalizations.of(context)?.selectPlanPrompt ?? 'Select a plan first',
                            style: const TextStyle(color: AppColors.textPrimary),
                          ),
                        ),
                        TextButton(
                          onPressed: widget.onPickPlan,
                          child: Text(AppLocalizations.of(context)?.goSelect ?? 'Go Select'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                GradientCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.selectedPlan?.name ?? (AppLocalizations.of(context)?.noPlanSelected ?? 'No Plan Selected'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String>(
                        key: ValueKey(_period),
                        initialValue: _period,
                        items: periods
                            .map(
                              (p) => DropdownMenuItem(
                                value: p,
                                child: Text(_periodLabel(p)),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value != null) setState(() => _period = value);
                        },
                        decoration: InputDecoration(labelText: AppLocalizations.of(context)?.subscriptionPeriod ?? 'Subscription Period'),
                      ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _couponController,
                    decoration: InputDecoration(labelText: AppLocalizations.of(context)?.coupon ?? 'Coupon (Optional)'),
                  ),
                  const SizedBox(height: 12),
                  Center(
                    child: GlowButton(
                      label: AppLocalizations.of(context)?.buyNow ?? 'Buy Now',
                      onPressed: _loading || methods.isEmpty ? null : _createOrder,
                      isLoading: _loading,
                      icon: Icons.shopping_cart_checkout,
                    ),
                  ),
                ],
              ),
            ),
            if (methods.isNotEmpty) ...[
              const SizedBox(height: 18),
              SectionHeader(title: AppLocalizations.of(context)?.payMethod ?? 'Payment Method'),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: methods.map((method) {
                  final selected = _method?.id == method.id;
                  return GestureDetector(
                    onTap: () => setState(() => _method = method),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: selected ? AppColors.surfaceAlt : AppColors.surface,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: selected ? AppColors.accent : AppColors.border,
                        ),
                      ),
                      child: Text(method.name),
                    ),
                  );
                }).toList(),
              ),
            ] else ...[
              const SizedBox(height: 18),
              Center(
                 child: Text(
                   AppLocalizations.of(context)?.noPaymentMethods ?? 'No payment methods available',
                   style: TextStyle(color: AppColors.textPrimary.withOpacity(0.5), fontSize: 13),
                 ),
              ),
            ],
            if (_message != null) ...[
              const SizedBox(height: 12),
              Center(
                child: Text(
                  _message!,
                  style: const TextStyle(color: AppColors.accentWarm),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
              ],
            );
          },
        ),
      ),
    );
  }
}
