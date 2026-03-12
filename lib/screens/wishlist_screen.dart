import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:path_provider/path_provider.dart';

class WishlistScreen extends StatefulWidget {
  const WishlistScreen({super.key});

  @override
  State<WishlistScreen> createState() => _WishlistScreenState();
}

class _WishlistScreenState extends State<WishlistScreen> {
  final _database = FirebaseDatabase.instance.ref();
  final _firestore = FirebaseFirestore.instance;
  
  List<Map<String, dynamic>> _submissions = [];
  List<Map<String, dynamic>> _searchResults = [];
  List<Map<String, dynamic>> _manualItems = [];
  Map<String, bool> _selectedSubmissions = {};
  
  double _globalDiscount = 0.0;
  bool _isLoading = true;
  String _searchQuery = "";

  @override
  void initState() {
    super.initState();
    _listenToWishlists();
    _listenToDiscount();
  }

  void _listenToWishlists() {
    _database.child('wishlist_submissions').onValue.listen((event) {
      if (event.snapshot.exists) {
        final data = event.snapshot.value as Map<dynamic, dynamic>;
        final List<Map<String, dynamic>> loadedSubmissions = [];
        
        data.forEach((key, value) {
          final submission = Map<String, dynamic>.from(value as Map);
          submission['id'] = key;
          
          // Ensure all items have a quantity field
          final List items = List.from(submission['items'] ?? []);
          for (var item in items) {
            item['quantity'] ??= 1;
          }
          submission['items'] = items;
          
          loadedSubmissions.add(submission);
        });

        // Sort by timestamp descending
        loadedSubmissions.sort((a, b) => (b['timestamp'] ?? 0).compareTo(a['timestamp'] ?? 0));

        setState(() {
          _submissions = loadedSubmissions;
          _isLoading = false;
        });
      } else {
        setState(() {
          _submissions = [];
          _isLoading = false;
        });
      }
    });
  }

  void _listenToDiscount() {
    _firestore.collection('settings').doc('discount').snapshots().listen((doc) {
      if (doc.exists) {
        final data = doc.data() as Map<String, dynamic>;
        setState(() {
          _globalDiscount = (data['amount'] ?? 0.0).toDouble();
        });
      }
    });
  }

  Future<void> _searchProducts(String query) async {
    if (query.isEmpty) {
      setState(() => _searchResults = []);
      return;
    }

    final nameQuery = await _firestore
        .collection('products')
        .where('Product_Name', isGreaterThanOrEqualTo: query)
        .where('Product_Name', isLessThanOrEqualTo: query + '\uf8ff')
        .get();

    final idQuery = await _firestore
        .collection('products')
        .where('Product_ID', isGreaterThanOrEqualTo: query)
        .where('Product_ID', isLessThanOrEqualTo: query + '\uf8ff')
        .get();

    final results = [...nameQuery.docs, ...idQuery.docs];
    final seenIds = <String>{};
    final uniqueResults = results.where((doc) {
      final id = doc.id;
      if (seenIds.contains(id)) return false;
      seenIds.add(id);
      return true;
    }).map((doc) => doc.data()).toList();

    setState(() {
      _searchResults = uniqueResults;
    });
  }

  Future<void> _addSearchResultToManual(Map<String, dynamic> product) async {
    final productId = product['Product_ID'];
    final stockDoc = await _firestore.collection('products').doc(productId).get();
    final stock = int.tryParse(stockDoc.data()?['Stock_Quantity']?.toString() ?? '0') ?? 0;

    if (stock <= 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Cannot add ${product['Product_Name']}: Out of stock"), backgroundColor: Colors.red),
        );
      }
      return;
    }

    setState(() {
      _manualItems.add({
        'name': product['Product_Name'],
        'price': product['Price_Min_INR'],
        'category': product['Category'],
        'id': productId,
        'quantity': 1
      });
      _searchResults = [];
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("${product['Product_Name']} added to manual items")),
    );
  }

  Future<void> _addProductToSubmission(String submissionId, Map<String, dynamic> product) async {
    final productId = product['Product_ID'];
    final stockDoc = await _firestore.collection('products').doc(productId).get();
    final stock = int.tryParse(stockDoc.data()?['Stock_Quantity']?.toString() ?? '0') ?? 0;

    if (stock <= 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Cannot add ${product['Product_Name']}: Out of stock"), backgroundColor: Colors.red),
        );
      }
      return;
    }

    setState(() {
      final subIndex = _submissions.indexWhere((s) => s['id'] == submissionId);
      if (subIndex != -1) {
        final items = List<Map<String, dynamic>>.from(_submissions[subIndex]['items'].map((e) => Map<String, dynamic>.from(e)));
        items.add({
          'name': product['Product_Name'],
          'price': product['Price_Min_INR'],
          'category': product['Category'],
          'id': productId,
          'quantity': 1
        });
        _submissions[subIndex]['items'] = items;
        _recalculateSubmissionSummary(subIndex);
      }
      _searchResults = [];
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("${product['Product_Name']} added to wishlist")),
    );
  }

  void _removeItemFromSubmission(String submissionId, int itemIndex) {
    setState(() {
      final subIndex = _submissions.indexWhere((s) => s['id'] == submissionId);
      if (subIndex != -1) {
        final items = List<Map<String, dynamic>>.from(_submissions[subIndex]['items'].map((e) => Map<String, dynamic>.from(e)));
        items.removeAt(itemIndex);
        _submissions[subIndex]['items'] = items;
        _recalculateSubmissionSummary(subIndex);
      }
    });
  }

  Future<void> _updateItemQuantity(String submissionId, int itemIndex, int delta) async {
    final subIndex = _submissions.indexWhere((s) => s['id'] == submissionId);
    if (subIndex == -1) return;

    final item = _submissions[subIndex]['items'][itemIndex];
    final int currentQty = item['quantity'] ?? 1;
    final int requestedQty = currentQty + delta;

    if (requestedQty <= 0) return;

    if (delta > 0) {
      final productId = item['id'];
      final stockDoc = await _firestore.collection('products').doc(productId).get();
      final availableStock = int.tryParse(stockDoc.data()?['Stock_Quantity']?.toString() ?? '0') ?? 0;

      if (requestedQty > availableStock) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("Stock limit reached! Only $availableStock items available."),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }
    }

    setState(() {
      final items = List<Map<String, dynamic>>.from(_submissions[subIndex]['items'].map((e) => Map<String, dynamic>.from(e)));
      items[itemIndex]['quantity'] = requestedQty;
      _submissions[subIndex]['items'] = items;
      _recalculateSubmissionSummary(subIndex);
    });
  }

  Future<void> _updateManualItemQuantity(int index, int delta) async {
    final item = _manualItems[index];
    final int currentQty = item['quantity'] ?? 1;
    final int requestedQty = currentQty + delta;

    if (requestedQty <= 0) return;

    if (delta > 0) {
      final productId = item['id'];
      final stockDoc = await _firestore.collection('products').doc(productId).get();
      final availableStock = int.tryParse(stockDoc.data()?['Stock_Quantity']?.toString() ?? '0') ?? 0;

      if (requestedQty > availableStock) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("Stock limit reached! Only $availableStock items available."),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }
    }

    setState(() {
      _manualItems[index]['quantity'] = requestedQty;
    });
  }

  void _recalculateSubmissionSummary(int subIndex) {
    final sub = _submissions[subIndex];
    final List items = sub['items'];
    final double subtotal = items.fold(0.0, (sum, item) {
      return sum + ((item['price'] ?? 0) * (item['quantity'] ?? 1));
    });
    final double discountPercent = (sub['summary']['discountPercentage'] ?? 0).toDouble();
    final double discountAmount = subtotal * (discountPercent / 100);
    final double total = subtotal - discountAmount;
    
    _submissions[subIndex]['summary'] = {
      'subtotal': subtotal,
      'discountPercentage': discountPercent,
      'discountAmount': discountAmount,
      'total': total,
    };
  }

  double _calculateSelectedTotal() {
    double total = 0;
    for (var sub in _submissions) {
      if (_selectedSubmissions[sub['id']] == true) {
        total += (sub['summary']['total'] ?? 0).toDouble();
      }
    }
    
    // Calculate total for manual items with global discount
    double manualSubtotal = _manualItems.fold(0.0, (sum, item) {
      return sum + ((item['price'] ?? 0) * (item['quantity'] ?? 1));
    });
    double manualDiscount = manualSubtotal * (_globalDiscount / 100);
    total += (manualSubtotal - manualDiscount);
    
    return total;
  }

  Future<void> _generatePdf() async {
    final pdf = pw.Document();
    final selectedSubmissions = _submissions.where((s) => _selectedSubmissions[s['id']] == true).toList();
    
    if (selectedSubmissions.isEmpty && _manualItems.isEmpty) return;

    pdf.addPage(
      pw.Page(
        build: (pw.Context context) {
          double totalSubtotal = selectedSubmissions.fold(0.0, (sum, s) => sum + (s['summary']['subtotal'] ?? 0)) +
                                _manualItems.fold(0.0, (sum, i) => sum + ((i['price'] ?? 0) * (i['quantity'] ?? 1)));
          
          double totalDiscount = selectedSubmissions.fold(0.0, (sum, s) => sum + (s['summary']['discountAmount'] ?? 0)) +
                                 (_manualItems.fold(0.0, (sum, i) => sum + ((i['price'] ?? 0) * (i['quantity'] ?? 1))) * (_globalDiscount / 100));
          
          double finalTotal = totalSubtotal - totalDiscount;

          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Header(level: 0, child: pw.Text("GENEX STORE BILL")),
              pw.Text("Date: ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}"),
              pw.SizedBox(height: 10),
              if (selectedSubmissions.isNotEmpty)
                pw.Text("Customers: ${selectedSubmissions.map((s) => s['customerName'] ?? 'Anonymous').join(', ')}", style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 20),
              pw.Table.fromTextArray(
                context: context,
                data: <List<String>>[
                  <String>['Product', 'Qty', 'Price', 'Subtotal'],
                  ...selectedSubmissions.expand((s) => (s['items'] as List).map((i) {
                    final double p = (i['price'] ?? 0).toDouble();
                    final int q = (i['quantity'] ?? 1).toInt();
                    return [i['name'].toString(), q.toString(), "Rs. $p", "Rs. ${p * q}"];
                  })),
                  ..._manualItems.map((i) {
                    final double p = (i['price'] ?? 0).toDouble();
                    final int q = (i['quantity'] ?? 1).toInt();
                    return [i['name'].toString(), q.toString(), "Rs. $p", "Rs. ${p * q}"];
                  }),
                ],
              ),
              pw.Divider(),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text("Subtotal:"),
                  pw.Text("Rs. ${totalSubtotal.toStringAsFixed(0)}"),
                ],
              ),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text("Total Discount:"),
                  pw.Text("Rs. ${totalDiscount.toStringAsFixed(0)}"),
                ],
              ),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text("Final Total:", style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                  pw.Text("Rs. ${finalTotal.toStringAsFixed(0)}", style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                ],
              ),
            ],
          );
        },
      ),
    );

    await Printing.layoutPdf(onLayout: (PdfPageFormat format) async => pdf.save());
  }

  void _showAddProductDialog(Map<String, dynamic> product) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Add Product to..."),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.add_shopping_cart, color: Colors.orange),
              title: const Text("Manual Items List"),
              onTap: () {
                _addSearchResultToManual(product);
                Navigator.pop(context);
              },
            ),
            const Divider(),
            if (_submissions.isEmpty) 
              const Padding(
                padding: EdgeInsets.all(8.0),
                child: Text("No active wishlists available"),
              ),
            ..._submissions.take(5).map((sub) => ListTile(
              leading: const Icon(Icons.person, color: Colors.blue),
              title: Text(sub['customerName'] ?? "Anonymous"),
              subtitle: Text("ID: ${sub['id'].toString().substring(0, 5)}..."),
              onTap: () {
                _addProductToSubmission(sub['id'], product);
                Navigator.pop(context);
              },
            )),
          ],
        ),
      ),
    );
  }

  void _deleteSubmission(String submissionId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Delete Wishlist?"),
        content: const Text("This will permanently remove this customer's wishlist. Are you sure?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("CANCEL")),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("DELETE", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await _database.child('wishlist_submissions').child(submissionId).remove();
        setState(() {
          _selectedSubmissions.remove(submissionId);
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Wishlist deleted successfully")),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Error deleting wishlist: $e")),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Customer Wishlists', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.blue.shade50,
        actions: [
          IconButton(
            icon: const Icon(Icons.picture_as_pdf),
            onPressed: _generatePdf,
            tooltip: 'Generate Bill PDF',
          )
        ],
      ),
      body: Column(
        children: [
          // Search Bar
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search Product to Add...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(15)),
                filled: true,
                fillColor: Colors.grey.shade100,
              ),
              onChanged: (val) {
                _searchQuery = val;
                _searchProducts(val);
              },
            ),
          ),

          // Search Results
          if (_searchResults.isNotEmpty)
            Container(
              height: 200,
              decoration: BoxDecoration(color: Colors.blue.shade50, border: Border.all(color: Colors.blue.shade100)),
              child: ListView.builder(
                itemCount: _searchResults.length,
                itemBuilder: (ctx, i) {
                  final prod = _searchResults[i];
                  return ListTile(
                    title: Text(prod['Product_Name'] ?? 'No Name'),
                    subtitle: Text("ID: ${prod['Product_ID']} | ₹${prod['Price_Min_INR']}"),
                    trailing: const Icon(Icons.add_circle, color: Colors.blue),
                    onTap: () => _showAddProductDialog(prod),
                  );
                },
              ),
            ),

          // Manual Items Header
          if (_manualItems.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(10),
              color: Colors.orange.shade50,
              child: Row(
                children: [
                  const Icon(Icons.add_shopping_cart, color: Colors.orange, size: 20),
                  const SizedBox(width: 8),
                  Text("Manually Added Products (${_manualItems.length})", 
                       style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.orange)),
                ],
              ),
            ),

          // Main Wishlist Feed
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : (_submissions.isEmpty && _manualItems.isEmpty)
                    ? const Center(child: Text("No wishlists or items to display"))
                    : ListView(
                        children: [
                          // Manual Items List
                          ..._manualItems.asMap().entries.map((entry) {
                            final idx = entry.key;
                            final item = entry.value;
                            final int qty = item['quantity'] ?? 1;
                            return Card(
                              margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              color: Colors.orange.shade50.withOpacity(0.3),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                              child: ListTile(
                                leading: const Icon(Icons.star, color: Colors.orange),
                                title: Text(item['name']),
                                subtitle: Row(
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.remove_circle_outline, size: 18),
                                      onPressed: () => _updateManualItemQuantity(idx, -1),
                                    ),
                                    Text("$qty", style: const TextStyle(fontWeight: FontWeight.bold)),
                                    IconButton(
                                      icon: const Icon(Icons.add_circle_outline, size: 18),
                                      onPressed: () => _updateManualItemQuantity(idx, 1),
                                    ),
                                    const Spacer(),
                                    Text("₹${(item['price'] ?? 0) * qty}"),
                                  ],
                                ),
                                trailing: IconButton(
                                  icon: const Icon(Icons.remove_circle, color: Colors.red),
                                  onPressed: () {
                                    setState(() {
                                      _manualItems.removeAt(idx);
                                    });
                                  },
                                ),
                              ),
                            );
                          }),

                          // RTDB Submissions
                          ..._submissions.asMap().entries.map((entry) {
                            final subIdx = entry.key;
                            final sub = entry.value;
                            final items = sub['items'] as List;
                            final summary = sub['summary'] as Map;
                            final date = DateTime.fromMillisecondsSinceEpoch(sub['timestamp'] ?? 0);
                            final customerName = sub['customerName'] ?? "Anonymous Customer";

                            return Card(
                              margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                              child: ExpansionTile(
                                leading: Checkbox(
                                  value: _selectedSubmissions[sub['id']] ?? false,
                                  onChanged: (val) {
                                    setState(() {
                                      _selectedSubmissions[sub['id']] = val ?? false;
                                    });
                                  },
                                ),
                                title: Text(customerName, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blue)),
                                subtitle: Text(DateFormat('MMM dd, yyyy HH:mm').format(date)),
                                trailing: IconButton(
                                  icon: const Icon(Icons.delete, color: Colors.redAccent),
                                  onPressed: () => _deleteSubmission(sub['id']),
                                ),
                                children: [
                                  const Divider(),
                                  ...items.asMap().entries.map((itemEntry) {
                                    final itemIdx = itemEntry.key;
                                    final item = itemEntry.value;
                                    final int q = item['quantity'] ?? 1;
                                    return ListTile(
                                      title: Text(item['name']),
                                      subtitle: Row(
                                        children: [
                                          IconButton(
                                            icon: const Icon(Icons.remove_circle_outline, size: 18),
                                            onPressed: () => _updateItemQuantity(sub['id'], itemIdx, -1),
                                          ),
                                          Text("$q", style: const TextStyle(fontWeight: FontWeight.bold)),
                                          IconButton(
                                            icon: const Icon(Icons.add_circle_outline, size: 18),
                                            onPressed: () => _updateItemQuantity(sub['id'], itemIdx, 1),
                                          ),
                                          const Spacer(),
                                          Text("₹${(item['price'] ?? 0) * q}"),
                                        ],
                                      ),
                                      trailing: IconButton(
                                        icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                                        onPressed: () => _removeItemFromSubmission(sub['id'], itemIdx),
                                      ),
                                    );
                                  }),
                                  const Divider(),
                                  Padding(
                                    padding: const EdgeInsets.all(12.0),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.end,
                                      children: [
                                        Text("Subtotal: ₹${summary['subtotal'].toStringAsFixed(0)}"),
                                        Text("Discount (${summary['discountPercentage']}%): -₹${summary['discountAmount'].toStringAsFixed(0)}",
                                            style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold)),
                                        Text("Total: ₹${summary['total'].toStringAsFixed(0)}",
                                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                                      ],
                                    ),
                                  )
                                ],
                              ),
                            );
                          }).toList(),
                        ],
                      ),
          ),
          
          // Bottom Summary
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 10, offset: const Offset(0, -5))],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text("Consolidated Total:", style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
                    Text("₹${_calculateSelectedTotal().toStringAsFixed(0)}", 
                         style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.blue)),
                  ],
                ),
                ElevatedButton.icon(
                  onPressed: _generatePdf,
                  icon: const Icon(Icons.receipt),
                  label: const Text("GENERATE BILL"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                  ),
                )
              ],
            ),
          )
        ],
      ),
    );
  }
}
