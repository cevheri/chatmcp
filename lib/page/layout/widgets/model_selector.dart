import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:ChatMcp/provider/provider_manager.dart';
import 'package:ChatMcp/provider/chat_model_provider.dart';
import 'package:ChatMcp/llm/model.dart';
import 'package:ChatMcp/llm/llm_factory.dart';

class ModelSelector extends StatelessWidget {
  const ModelSelector({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatModelProvider>(
      builder: (context, chatModelProvider, child) {
        final availableModels = ProviderManager
            .chatModelProvider.availableModels
            .where((model) => LLMFactoryHelper.isChatModel(model))
            .toList();

        return Container(
          constraints: const BoxConstraints(maxWidth: 250),
          child: PopupMenuButton<String>(
            offset: const Offset(0, 8),
            position: PopupMenuPosition.under,
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.8,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      availableModels
                          .firstWhere(
                            (model) =>
                                model.name ==
                                chatModelProvider.currentModel.name,
                            orElse: () =>
                                Model(name: '', label: 'NaN', provider: ''),
                          )
                          .label,
                      style: Theme.of(context).textTheme.bodyMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.expand_more,
                    size: 18,
                    color: Theme.of(context).iconTheme.color,
                  ),
                ],
              ),
            ),
            itemBuilder: (context) {
              // 按 provider 对模型进行分组
              final modelsByProvider = <String, List<Model>>{};
              for (var model in availableModels) {
                modelsByProvider
                    .putIfAbsent(model.provider, () => [])
                    .add(model);
              }

              // 构建菜单项列表
              final menuItems = <PopupMenuEntry<String>>[];
              modelsByProvider.forEach((provider, models) {
                // 添加 provider 标题
                if (menuItems.isNotEmpty) {
                  menuItems.add(const PopupMenuDivider());
                }
                menuItems.add(
                  PopupMenuItem<String>(
                    enabled: false,
                    height: 16,
                    child: Text(
                      provider,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ),
                );

                // 添加该 provider 下的所有模型
                for (var model in models) {
                  menuItems.add(
                    PopupMenuItem<String>(
                      value: model.name,
                      height: 32,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 8.0),
                        child: Row(
                          children: [
                            if (model.name == chatModelProvider.currentModel)
                              Icon(
                                Icons.check,
                                size: 18,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            if (model.name ==
                                chatModelProvider.currentModel.name)
                              const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                model.label,
                                style: TextStyle(
                                  color: model.name ==
                                          chatModelProvider.currentModel.name
                                      ? Theme.of(context).colorScheme.primary
                                      : null,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }
              });

              return menuItems;
            },
            onSelected: (String value) {
              final selectedModel = availableModels.firstWhere(
                (model) => model.name == value,
              );
              ProviderManager.chatModelProvider.currentModel = selectedModel;
            },
          ),
        );
      },
    );
  }
}
