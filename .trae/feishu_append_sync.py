import os
import sys
import json
import urllib.request
import urllib.error

# ==========================================
# 飞书应用配置信息 
# ==========================================
APP_ID = "cli_a948ffd892ba1cc2"
APP_SECRET = "LDSo11pgkDtZMYUEjfiLWcPCGIBzKp7y"

def get_tenant_access_token():
    """获取飞书 tenant_access_token"""
    url = "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal"
    headers = {"Content-Type": "application/json"}
    data = {
        "app_id": APP_ID,
        "app_secret": APP_SECRET
    }
    
    req = urllib.request.Request(url, data=json.dumps(data).encode('utf-8'), headers=headers)
    try:
        response = urllib.request.urlopen(req)
        result = json.loads(response.read().decode('utf-8'))
        if result.get("code") == 0:
            return result.get("tenant_access_token")
        else:
            print(f"获取 token 失败: {result.get('msg')}")
            sys.exit(1)
    except Exception as e:
        print(f"请求 token 发生异常: {e}")
        sys.exit(1)

def get_document_id_from_wiki(wiki_token, token):
    """
    通过 wiki_token 获取底层的 document_id (obj_token)
    文档：https://open.feishu.cn/document/server-docs/docs/wiki-v2/space-node/get_node
    """
    url = f"https://open.feishu.cn/open-apis/wiki/v2/spaces/get_node?token={wiki_token}"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json; charset=utf-8"
    }
    
    req = urllib.request.Request(url, headers=headers)
    try:
        response = urllib.request.urlopen(req)
        result = json.loads(response.read().decode('utf-8'))
        if result.get("code") == 0:
            node = result.get("data", {}).get("node", {})
            return node.get("obj_token")
        else:
            print(f"获取 wiki 节点信息失败: {result.get('msg')}")
            sys.exit(1)
    except urllib.error.HTTPError as e:
        error_body = e.read().decode('utf-8')
        print(f"请求 wiki 节点失败: HTTP {e.code} - {error_body}")
        sys.exit(1)
    except Exception as e:
        print(f"请求 wiki 节点发生异常: {e}")
        sys.exit(1)

def append_blocks_to_document(document_id, token, content):
    """
    向飞书文档 (docx) 追加内容块
    API: POST /open-apis/docx/v1/documents/{document_id}/blocks/{block_id}/children
    """
    # 飞书文档追加内容，父 block_id 就是 document_id
    url = f"https://open.feishu.cn/open-apis/docx/v1/documents/{document_id}/blocks/{document_id}/children"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json; charset=utf-8"
    }
    
    # 将内容按换行符拆分成多个 text 块，避免单块过大
    lines = content.split('\n')
    children = []
    for line in lines:
        children.append({
            "block_type": 2,  # 2 表示 Text 文本块
            "text": {
                "elements": [
                    {
                        "text_run": {
                            "content": line
                        }
                    }
                ]
            }
        })
    
    # 限制单次追加的块数量（飞书 API 限制单次最多 100 个 block，安全起见我们这里切片）
    batch_size = 50
    for i in range(0, len(children), batch_size):
        batch_children = children[i:i+batch_size]
        data = {
            "children": batch_children
        }
        
        req = urllib.request.Request(url, data=json.dumps(data).encode('utf-8'), headers=headers)
        try:
            response = urllib.request.urlopen(req)
            result = json.loads(response.read().decode('utf-8'))
            if result.get("code") == 0:
                print(f"成功追加了 {len(batch_children)} 行内容")
            else:
                print(f"追加内容失败: {result.get('msg')}")
                # 不退出，继续尝试追加后面的
        except urllib.error.HTTPError as e:
             error_body = e.read().decode('utf-8')
             print(f"HTTPError 追加内容失败: {e.code} - {error_body}")
        except Exception as e:
            print(f"请求追加内容发生异常: {e}")

def extract_wiki_token(url):
    """从飞书 wiki 链接中提取 token"""
    # 移除可能存在的反引号或多余空格
    url = url.replace("`", "").strip()
    # https://ucnf79c7lcnh.feishu.cn/wiki/XBUBwu1oIiITWCkPzlScrPeynNh -> XBUBwu1oIiITWCkPzlScrPeynNh
    if "/wiki/" in url:
        return url.split("/wiki/")[-1].split("?")[0].split("#")[0]
    return url

def main():
    if len(sys.argv) < 3:
        print("用法: python feishu_append.py <飞书文档链接> <文件路径或文本内容>")
        print("示例1 (文件): python feishu_append.py https://.../wiki/XBUB... ./my_content.txt")
        print("示例2 (文本): python feishu_append.py https://.../wiki/XBUB... '这是直接传入的文本'")
        sys.exit(1)

    target_url = sys.argv[1]
    input_source = sys.argv[2]
    
    # 判断是文件还是文本
    content = ""
    if os.path.isfile(input_source):
        try:
            with open(input_source, 'r', encoding='utf-8') as f:
                content = f.read()
            print(f"读取文件内容成功，共 {len(content)} 字符")
        except Exception as e:
            print(f"读取文件失败: {e}")
            sys.exit(1)
    else:
        content = input_source
        print(f"识别为直接传入的文本，共 {len(content)} 字符")

    if not content.strip():
        print("内容为空，无需追加")
        sys.exit(0)

    # 1. 获取 token
    print("正在获取飞书 access_token...")
    access_token = get_tenant_access_token()
    
    # 2. 提取并转换 token
    wiki_token = extract_wiki_token(target_url)
    print(f"提取到 wiki_token: {wiki_token}")
    
    document_id = get_document_id_from_wiki(wiki_token, access_token)
    print(f"转换得到真实的 document_id: {document_id}")
    
    # 3. 追加内容
    print("开始追加内容到文档末尾...")
    append_blocks_to_document(document_id, access_token, content)
    print("执行完毕！")

if __name__ == "__main__":
    main()
